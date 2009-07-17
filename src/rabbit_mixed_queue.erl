%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_mixed_queue).

-include("rabbit.hrl").

-export([init/2]).

-export([publish/2, publish_delivered/2, deliver/1, ack/2,
         tx_publish/2, tx_commit/3, tx_cancel/2, requeue/2, purge/1,
         length/1, is_empty/1, delete_queue/1]).

-export([to_disk_only_mode/2, to_mixed_mode/2, estimate_queue_memory/1,
         reset_counters/1, info/1]).

-record(mqstate, { mode,
                   msg_buf,
                   queue,
                   is_durable,
                   length,
                   memory_size,
                   memory_gain,
                   memory_loss
                 }
       ).

-define(TO_DISK_MAX_FLUSH_SIZE, 100000).

-ifdef(use_specs).

-type(mode() :: ( 'disk' | 'mixed' )).
-type(mqstate() :: #mqstate { mode :: mode(),
                              msg_buf :: queue(),
                              queue :: queue_name(),
                              is_durable :: bool(),
                              length :: non_neg_integer(),
                              memory_size :: non_neg_integer(),
                              memory_gain :: non_neg_integer(),
                              memory_loss :: non_neg_integer()
                            }).
-type(acktag() :: ( 'noack' | { non_neg_integer(), non_neg_integer() })).
-type(okmqs() :: {'ok', mqstate()}).

-spec(init/2 :: (queue_name(), bool()) -> okmqs()).
-spec(publish/2 :: (message(), mqstate()) -> okmqs()).
-spec(publish_delivered/2 :: (message(), mqstate()) ->
             {'ok', acktag(), mqstate()}).
-spec(deliver/1 :: (mqstate()) ->
             {('empty' | {message(), bool(), acktag(), non_neg_integer()}),
              mqstate()}).
-spec(ack/2 :: ([acktag()], mqstate()) -> okmqs()).
-spec(tx_publish/2 :: (message(), mqstate()) -> okmqs()).
-spec(tx_commit/3 :: ([message()], [acktag()], mqstate()) -> okmqs()).
-spec(tx_cancel/2 :: ([message()], mqstate()) -> okmqs()).
-spec(requeue/2 :: ([{message(), acktag()}], mqstate()) -> okmqs()).
-spec(purge/1 :: (mqstate()) -> okmqs()).
             
-spec(delete_queue/1 :: (mqstate()) -> {'ok', mqstate()}).
             
-spec(length/1 :: (mqstate()) -> non_neg_integer()).
-spec(is_empty/1 :: (mqstate()) -> bool()).

-spec(to_disk_only_mode/2 :: ([message()], mqstate()) -> okmqs()).
-spec(to_mixed_mode/2 :: ([message()], mqstate()) -> okmqs()).

-spec(estimate_queue_memory/1 :: (mqstate()) ->
             {non_neg_integer, non_neg_integer, non_neg_integer}).
-spec(reset_counters/1 :: (mqstate()) -> (mqstate())).
-spec(info/1 :: (mqstate()) -> mode()).

-endif.

init(Queue, IsDurable) ->
    Len = rabbit_disk_queue:length(Queue),
    MsgBuf = inc_queue_length(Queue, queue:new(), Len),
    Size = rabbit_disk_queue:foldl(
             fun ({Msg = #basic_message { is_persistent = true },
                   _Size, _IsDelivered, _AckTag}, Acc) ->
                     Acc + size_of_message(Msg)
             end, 0, Queue),
    {ok, #mqstate { mode = disk, msg_buf = MsgBuf, queue = Queue,
                    is_durable = IsDurable, length = Len,
                    memory_size = Size, memory_gain = undefined,
                    memory_loss = undefined }}.

size_of_message(
  #basic_message { content = #content { payload_fragments_rev = Payload }}) ->
    lists:foldl(fun (Frag, SumAcc) ->
                        SumAcc + size(Frag)
                end, 0, Payload).

to_disk_only_mode(_TxnMessages, State = #mqstate { mode = disk }) ->
    {ok, State};
to_disk_only_mode(TxnMessages, State =
                  #mqstate { mode = mixed, queue = Q, msg_buf = MsgBuf,
                             is_durable = IsDurable }) ->
    rabbit_log:info("Converting queue to disk only mode: ~p~n", [Q]),
    %% We enqueue _everything_ here. This means that should a message
    %% already be in the disk queue we must remove it and add it back
    %% in. Fortunately, by using requeue, we avoid rewriting the
    %% message on disk.
    %% Note we also batch together messages on disk so that we minimise
    %% the calls to requeue.
    {ok, MsgBuf1} =
        send_messages_to_disk(IsDurable, Q, MsgBuf, 0, 0, [], queue:new()),
    %% tx_publish txn messages. Some of these will have been already
    %% published if they really are durable and persistent which is
    %% why we can't just use our own tx_publish/2 function (would end
    %% up publishing twice, so refcount would go wrong in disk_queue).
    lists:foreach(
      fun (Msg = #basic_message { is_persistent = IsPersistent }) ->
              ok = case IsDurable andalso IsPersistent of
                       true -> ok;
                       _    -> rabbit_disk_queue:tx_publish(Msg)
                   end
      end, TxnMessages),
    garbage_collect(),
    {ok, State #mqstate { mode = disk, msg_buf = MsgBuf1 }}.

send_messages_to_disk(IsDurable, Q, Queue, PublishCount, RequeueCount,
                      Commit, MsgBuf) ->
    case queue:out(Queue) of
        {empty, Queue} ->
            ok = flush_messages_to_disk_queue(Q, Commit),
            [] = flush_requeue_to_disk_queue(Q, RequeueCount, []),
            {ok, MsgBuf};
        {{value, {Msg = #basic_message { guid = MsgId,
                                         is_persistent = IsPersistent },
                  _IsDelivered}}, Queue1} ->
            case IsDurable andalso IsPersistent of
                true -> %% it's already in the Q
                    send_messages_to_disk(
                      IsDurable, Q, Queue1, PublishCount, RequeueCount,
                      Commit, inc_queue_length(Q, MsgBuf, 1));
                false ->
                    Commit1 = flush_requeue_to_disk_queue
                                (Q, RequeueCount, Commit),
                    ok = rabbit_disk_queue:tx_publish(Msg),
                    case PublishCount == ?TO_DISK_MAX_FLUSH_SIZE of
                        true ->
                            ok = flush_messages_to_disk_queue(Q, Commit1),
                            send_messages_to_disk(
                              IsDurable, Q, Queue1, 1, 0, [MsgId],
                              inc_queue_length(Q, MsgBuf, 1));
                        false ->
                            send_messages_to_disk(
                              IsDurable, Q, Queue1, PublishCount + 1, 0,
                              [MsgId | Commit1],
                              inc_queue_length(Q, MsgBuf, 1))
                    end
            end;
        {{value, {Q, Count}}, Queue1} ->
            send_messages_to_disk(IsDurable, Q, Queue1, PublishCount,
                                  RequeueCount, Commit,
                                  inc_queue_length(Q, MsgBuf, Count))
    end.

flush_messages_to_disk_queue(Q, Commit) ->
    ok = if [] == Commit -> ok;
            true -> rabbit_disk_queue:tx_commit(Q, lists:reverse(Commit), [])
         end.

flush_requeue_to_disk_queue(Q, RequeueCount, Commit) ->
    if 0 == RequeueCount -> Commit;
       true ->
            ok = if [] == Commit -> ok;
                    true -> rabbit_disk_queue:tx_commit
                              (Q, lists:reverse(Commit), [])
                 end,
            rabbit_disk_queue:requeue_next_n(Q, RequeueCount),
            []
    end.

to_mixed_mode(_TxnMessages, State = #mqstate { mode = mixed }) ->
    {ok, State};
to_mixed_mode(TxnMessages, State =
              #mqstate { mode = disk, queue = Q,
                         is_durable = IsDurable, msg_buf = MsgBuf }) ->
    rabbit_log:info("Converting queue to mixed mode: ~p~n", [Q]),
    %% load up a new queue with a token that says how many messages
    %% are on disk (this is already built for us by the disk mode)
    %% don't actually do anything to the disk
    ok = maybe_prefetch(mixed, MsgBuf),
    %% remove txn messages from disk which are neither persistent and
    %% durable. This is necessary to avoid leaks. This is also pretty
    %% much the inverse behaviour of our own tx_cancel/2 which is why
    %% we're not using it.
    Cancel =
        lists:foldl(
          fun (Msg = #basic_message { is_persistent = IsPersistent }, Acc) ->
                  case IsDurable andalso IsPersistent of
                      true -> Acc;
                      _    -> [Msg #basic_message.guid | Acc]
                  end
          end, [], TxnMessages),
    ok = if Cancel == [] -> ok;
            true -> rabbit_disk_queue:tx_cancel(Cancel)
         end,
    garbage_collect(),
    {ok, State #mqstate { mode = mixed }}.

inc_queue_length(_Queue, MsgBuf, 0) ->
    MsgBuf;
inc_queue_length(Queue, MsgBuf, Count) ->
    case queue:out_r(MsgBuf) of
        {empty, MsgBuf} ->
            queue:in({Queue, Count}, MsgBuf);
        {{value, {Queue, Len}}, MsgBuf1} ->
            queue:in({Queue, Len + Count}, MsgBuf1);
        {{value, _}, _MsgBuf1} ->
            queue:in({Queue, Count}, MsgBuf)
    end.

dec_queue_length(Mode, MsgBuf) ->
    {{value, {Queue, Len}}, MsgBuf1} = queue:out(MsgBuf),
    MsgBuf2 = case Len of
                  1 -> ok = maybe_prefetch(Mode, MsgBuf1),
                       MsgBuf1;
                  _ -> queue:in_r({Queue, Len-1}, MsgBuf1)
              end,
    {Queue, MsgBuf2}.

publish(Msg, State = #mqstate { mode = disk, queue = Q, length = Length,
                                msg_buf = MsgBuf, memory_size = QSize,
                                memory_gain = Gain }) ->
    MsgBuf1 = inc_queue_length(Q, MsgBuf, 1),
    ok = rabbit_disk_queue:publish(Q, Msg, false),
    MsgSize = size_of_message(Msg),
    {ok, State #mqstate { memory_gain = Gain + MsgSize,
                          memory_size = QSize + MsgSize,
                          msg_buf = MsgBuf1, length = Length + 1 }};
publish(Msg = #basic_message { is_persistent = IsPersistent }, State = 
        #mqstate { queue = Q, mode = mixed, is_durable = IsDurable,
                   msg_buf = MsgBuf, length = Length, memory_size = QSize,
                   memory_gain = Gain }) ->
    Persist = IsDurable andalso IsPersistent,
    ok = case Persist of
             true -> rabbit_disk_queue:publish(Q, Msg, false);
             false -> ok
         end,
    MsgSize = size_of_message(Msg),
    {ok, State #mqstate { msg_buf = queue:in({Msg, false}, MsgBuf),
                          length = Length + 1, memory_size = QSize + MsgSize,
                          memory_gain = Gain + MsgSize }}.

%% Assumption here is that the queue is empty already (only called via
%% attempt_immediate_delivery).
publish_delivered(Msg =
                  #basic_message { guid = MsgId, is_persistent = IsPersistent},
                  State =
                  #mqstate { mode = Mode, is_durable = IsDurable,
                             queue = Q, length = 0,
                             memory_size = QSize, memory_gain = Gain })
  when Mode =:= disk orelse (IsDurable andalso IsPersistent) ->
    Persist = IsDurable andalso IsPersistent,
    rabbit_disk_queue:publish(Q, Msg, false),
    MsgSize = size_of_message(Msg),
    State1 = State #mqstate { memory_size = QSize + MsgSize,
                              memory_gain = Gain + MsgSize },
    case Persist of
        true ->
            %% must call phantom_deliver otherwise the msg remains at
            %% the head of the queue. This is synchronous, but
            %% unavoidable as we need the AckTag
            {MsgId, IsPersistent, false, AckTag, 0} =
                rabbit_disk_queue:phantom_deliver(Q),
            {ok, AckTag, State1};
        false ->
            %% in this case, we don't actually care about the ack, so
            %% auto ack it (asynchronously).
            ok = rabbit_disk_queue:auto_ack_next_message(Q),
            {ok, noack, State1}
    end;
publish_delivered(Msg, State =
                  #mqstate { mode = mixed, length = 0, memory_size = QSize,
                             memory_gain = Gain }) ->
    MsgSize = size_of_message(Msg),
    {ok, noack, State #mqstate { memory_size = QSize + MsgSize,
                                 memory_gain = Gain + MsgSize }}.

deliver(State = #mqstate { length = 0 }) ->
    {empty, State};
deliver(State = #mqstate { msg_buf = MsgBuf, queue = Q,
                           is_durable = IsDurable, length = Length,
                           mode = Mode }) ->
    {{value, Value}, MsgBuf1} = queue:out(MsgBuf),
    {Msg, IsDelivered, AckTag, MsgBuf2} =
        case Value of
            {Msg1 = #basic_message { guid = MsgId,
                                     is_persistent = IsPersistent },
             IsDelivered1} ->
                AckTag1 =
                    case IsDurable andalso IsPersistent of
                        true ->
                            {MsgId, IsPersistent, IsDelivered1, AckTag2, _PRem}
                                = rabbit_disk_queue:phantom_deliver(Q),
                            AckTag2;
                        false ->
                            noack
                    end,
                ok = maybe_prefetch(Mode, MsgBuf1),
                {Msg1, IsDelivered1, AckTag1, MsgBuf1};
            _ ->
                {Q, MsgBuf3} = dec_queue_length(Mode, MsgBuf),
                {Msg1 = #basic_message { is_persistent = IsPersistent },
                 _Size, IsDelivered1, AckTag1, _PersistRem}
                    = rabbit_disk_queue:deliver(Q),
                AckTag2 =
                    case IsDurable andalso IsPersistent of
                        true ->
                            AckTag1;
                        false ->
                            ok = rabbit_disk_queue:ack(Q, [AckTag1]),
                            noack
                    end,
                {Msg1, IsDelivered1, AckTag2, MsgBuf3}
        end,
    Rem = Length - 1,
    {{Msg, IsDelivered, AckTag, Rem},
     State #mqstate { msg_buf = MsgBuf2, length = Rem }}.

maybe_prefetch(disk, _MsgBuf) ->
    ok;
maybe_prefetch(mixed, MsgBuf) ->
    case queue:peek(MsgBuf) of
        empty ->
            ok;
        {value, {#basic_message {}, _IsDelivered}} ->
            ok;
        {value, {Q, Count}} ->
            rabbit_disk_queue:prefetch(Q, Count)
    end.

remove_noacks(MsgsWithAcks) ->
    lists:foldl(
      fun ({Msg, noack}, {AccAckTags, AccSize}) ->
              {AccAckTags, size_of_message(Msg) + AccSize};
          ({Msg, AckTag}, {AccAckTags, AccSize}) ->
              {[AckTag | AccAckTags], size_of_message(Msg) + AccSize}
      end, {[], 0}, MsgsWithAcks).

ack(MsgsWithAcks, State = #mqstate { queue = Q, memory_size = QSize,
                                     memory_loss = Loss }) ->
    {AckTags, ASize} = remove_noacks(MsgsWithAcks),
    ok = case AckTags of
             [] -> ok;
             _ -> rabbit_disk_queue:ack(Q, AckTags)
         end,
    State1 = State #mqstate { memory_size = QSize - ASize,
                              memory_loss = Loss + ASize },
    {ok, State1}.
                                                   
tx_publish(Msg = #basic_message { is_persistent = IsPersistent },
           State = #mqstate { mode = Mode, memory_size = QSize,
                              is_durable = IsDurable, memory_gain = Gain })
  when Mode =:= disk orelse (IsDurable andalso IsPersistent) ->
    ok = rabbit_disk_queue:tx_publish(Msg),
    MsgSize = size_of_message(Msg),
    {ok, State #mqstate { memory_size = QSize + MsgSize,
                          memory_gain = Gain + MsgSize }};
tx_publish(Msg, State = #mqstate { mode = mixed, memory_size = QSize,
                                   memory_gain = Gain }) ->
    %% this message will reappear in the tx_commit, so ignore for now
    MsgSize = size_of_message(Msg),
    {ok, State #mqstate { memory_size = QSize + MsgSize,
                          memory_gain = Gain + MsgSize }}.

only_msg_ids(Pubs) ->
    lists:map(fun (Msg) -> Msg #basic_message.guid end, Pubs).

tx_commit(Publishes, MsgsWithAcks,
          State = #mqstate { mode = disk, queue = Q, length = Length,
                             memory_size = QSize, memory_loss = Loss,
                             msg_buf = MsgBuf }) ->
    {RealAcks, ASize} = remove_noacks(MsgsWithAcks),
    ok = if ([] == Publishes) andalso ([] == RealAcks) -> ok;
            true -> rabbit_disk_queue:tx_commit(Q, only_msg_ids(Publishes),
                                                RealAcks)
         end,
    Len = erlang:length(Publishes),
    {ok, State #mqstate { length = Length + Len,
                          msg_buf = inc_queue_length(Q, MsgBuf, Len),
                          memory_size = QSize - ASize,
                          memory_loss = Loss + ASize }};
tx_commit(Publishes, MsgsWithAcks,
          State = #mqstate { mode = mixed, queue = Q, msg_buf = MsgBuf,
                             is_durable = IsDurable, length = Length,
                             memory_size = QSize, memory_loss = Loss }) ->
    {PersistentPubs, MsgBuf1} =
        lists:foldl(fun (Msg = #basic_message { is_persistent = IsPersistent },
                         {Acc, MsgBuf2}) ->
                            Acc1 =
                                case IsPersistent andalso IsDurable of
                                    true -> [Msg #basic_message.guid | Acc];
                                    false -> Acc
                                end,
                            {Acc1, queue:in({Msg, false}, MsgBuf2)}
                    end, {[], MsgBuf}, Publishes),
    {RealAcks, ASize} = remove_noacks(MsgsWithAcks),
    ok = case ([] == PersistentPubs) andalso ([] == RealAcks) of
             true -> ok;
             false -> rabbit_disk_queue:tx_commit(
                        Q, lists:reverse(PersistentPubs), RealAcks)
         end,
    {ok, State #mqstate { msg_buf = MsgBuf1, memory_size = QSize - ASize,
                          length = Length + erlang:length(Publishes),
                          memory_loss = Loss + ASize }}.

tx_cancel(Publishes, State = #mqstate { mode = disk, memory_size = QSize,
                                        memory_loss = Loss }) ->
    {MsgIds, CSize} =
        lists:foldl(
          fun (Msg = #basic_message { guid = MsgId }, {MsgIdsAcc, CSizeAcc}) ->
                  {[MsgId | MsgIdsAcc], CSizeAcc + size_of_message(Msg)}
          end, {[], 0}, Publishes),
    ok = rabbit_disk_queue:tx_cancel(MsgIds),
    {ok, State #mqstate { memory_size = QSize - CSize,
                          memory_loss = Loss + CSize }};
tx_cancel(Publishes, State = #mqstate { mode = mixed, is_durable = IsDurable,
                                        memory_size = QSize,
                                        memory_loss = Loss }) ->
    {PersistentPubs, CSize} =
        lists:foldl(
          fun (Msg = #basic_message { is_persistent = IsPersistent,
                                      guid = MsgId }, {Acc, CSizeAcc}) ->
                  CSizeAcc1 = CSizeAcc + size_of_message(Msg),
                  {case IsPersistent of
                       true -> [MsgId | Acc];
                       _    -> Acc
                   end, CSizeAcc1}
          end, {[], 0}, Publishes),
    ok =
        if IsDurable ->
                rabbit_disk_queue:tx_cancel(PersistentPubs);
           true -> ok
        end,
    {ok, State #mqstate { memory_size = QSize - CSize,
                          memory_loss = Loss + CSize }}.

%% [{Msg, AckTag}]
requeue(MessagesWithAckTags, State = #mqstate { mode = disk, queue = Q,
                                                is_durable = IsDurable,
                                                length = Length,
                                                msg_buf = MsgBuf }) ->
    %% here, we may have messages with no ack tags, because of the
    %% fact they are not persistent, but nevertheless we want to
    %% requeue them. This means publishing them delivered.
    Requeue
        = lists:foldl(
            fun ({#basic_message { is_persistent = IsPersistent }, AckTag}, RQ)
                when IsDurable andalso IsPersistent ->
                    [{AckTag, true} | RQ];
                ({Msg, noack}, RQ) ->
                    ok = case RQ == [] of
                             true  -> ok;
                             false -> rabbit_disk_queue:requeue(
                                        Q, lists:reverse(RQ))
                         end,
                    ok = rabbit_disk_queue:publish(Q, Msg, true),
                    []
            end, [], MessagesWithAckTags),
    ok = rabbit_disk_queue:requeue(Q, lists:reverse(Requeue)),
    Len = erlang:length(MessagesWithAckTags),
    {ok, State #mqstate { length = Length + Len,
                          msg_buf = inc_queue_length(Q, MsgBuf, Len) }};
requeue(MessagesWithAckTags, State = #mqstate { mode = mixed, queue = Q,
                                                msg_buf = MsgBuf,
                                                is_durable = IsDurable,
                                                length = Length
                                              }) ->
    {PersistentPubs, MsgBuf1} =
        lists:foldl(
          fun ({Msg = #basic_message { is_persistent = IsPersistent }, AckTag},
               {Acc, MsgBuf2}) ->
                  Acc1 =
                      case IsDurable andalso IsPersistent of
                          true -> [{AckTag, true} | Acc];
                          false -> Acc
                      end,
                  {Acc1, queue:in({Msg, true}, MsgBuf2)}
          end, {[], MsgBuf}, MessagesWithAckTags),
    ok = case PersistentPubs of
             [] -> ok;
             _  -> rabbit_disk_queue:requeue(Q, lists:reverse(PersistentPubs))
         end,
    {ok, State #mqstate {msg_buf = MsgBuf1,
                         length = Length + erlang:length(MessagesWithAckTags)}}.

purge(State = #mqstate { queue = Q, mode = disk, length = Count,
                         memory_loss = Loss, memory_size = QSize }) ->
    Count = rabbit_disk_queue:purge(Q),
    {Count, State #mqstate { length = 0, memory_size = 0,
                             memory_loss = Loss + QSize }};
purge(State = #mqstate { queue = Q, mode = mixed, length = Length,
                         memory_loss = Loss, memory_size = QSize }) ->
    rabbit_disk_queue:purge(Q),
    {Length,
     State #mqstate { msg_buf = queue:new(), length = 0, memory_size = 0,
                      memory_loss = Loss + QSize }}.

delete_queue(State = #mqstate { queue = Q, memory_size = QSize,
                                memory_loss = Loss }) ->
    ok = rabbit_disk_queue:delete_queue(Q),
    {ok, State #mqstate { length = 0, memory_size = 0, msg_buf = queue:new(),
                          memory_loss = Loss + QSize }}.

length(#mqstate { length = Length }) ->
    Length.

is_empty(#mqstate { length = Length }) ->
    0 == Length.

estimate_queue_memory(#mqstate { memory_size = Size, memory_gain = Gain,
                                 memory_loss = Loss }) ->
    {4 * Size, Gain, Loss}.

reset_counters(State) ->
    State #mqstate { memory_gain = 0, memory_loss = 0 }.

info(#mqstate { mode = Mode }) ->
    Mode.
