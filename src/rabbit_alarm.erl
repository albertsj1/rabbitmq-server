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
%%   The Initial Developers of the Original Code are LShift Ltd.,
%%   Cohesive Financial Technologies LLC., and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd., Cohesive Financial Technologies
%%   LLC., and Rabbit Technologies Ltd. are Copyright (C) 2007-2008
%%   LShift Ltd., Cohesive Financial Technologies LLC., and Rabbit
%%   Technologies Ltd.;
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_alarm).

-behaviour(gen_event).

-export([start/0, stop/0, register/2]).

-export([init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MEMSUP_CHECK_INTERVAL, 1000).

-record(alarms, {alertees, system_memory_high_watermark = false}).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(mfa_tuple() :: {atom(), atom(), list()}).
-spec(start/0 :: () -> 'ok').
-spec(stop/0 :: () -> 'ok').
-spec(register/2 :: (pid(), mfa_tuple()) -> 'ok').
             
-endif.

%%----------------------------------------------------------------------------

start() ->
    ok = alarm_handler:add_alarm_handler(?MODULE),
    case whereis(memsup) of
        undefined ->
            {ok, _} =
                start_memsup(
                  case os:type() of 
                      %% memsup doesn't take account of buffers or
                      %% cache %% when considering "free" memory -
                      %% therefore on %% Linux we can get memory
                      %% alarms very easily %% without any pressure
                      %% existing on memory at all.  %% Therefore we
                      %% need to use our own simple memory %% monitor
                      %%
                      {unix, linux} -> rabbit_memsup_linux;

                      %% Start memsup programmatically rather than via
                      %% the rabbitmq-server script. This is not quite
                      %% the right thing to do as os_mon checks to see
                      %% if memsup is available before starting it,
                      %% but as memsup is available everywhere (even
                      %% on VXWorks) it should be ok.
                      %%
                      %% One benefit of the programmatic startup is
                      %% that we can add our alarm_handler before
                      %% memsup is running, thus ensuring that we
                      %% notice memory alarms that go off on startup.
                      %%
                      _             -> memsup
                  end),
            ok;
        _ ->
            ok
    end,
    %% The default memsup check interval is 1 minute, which is way too
    %% long - rabbit can gobble up all memory in a matter of seconds.
    %% Unfortunately the memory_check_interval configuration parameter
    %% and memsup:set_check_interval/1 function only provide a
    %% granularity of minutes. So we have to peel off one layer of the
    %% API to get to the underlying layer which operates at the
    %% granularity of milliseconds.
    %%
    %% Note that the new setting will only take effect after the first
    %% check has completed, i.e. after one minute. So if rabbit eats
    %% all the memory within the first minute after startup then we
    %% are out of luck.
    ok = os_mon:call(memsup,
                     {set_check_interval, ?MEMSUP_CHECK_INTERVAL},
                     infinity).

stop() ->
    ok = alarm_handler:delete_alarm_handler(?MODULE).

register(Pid, HighMemMFA) ->
    ok = gen_event:call(alarm_handler, ?MODULE,
                        {register, Pid, HighMemMFA}).

%%----------------------------------------------------------------------------

init([]) ->
    {ok, #alarms{alertees = dict:new()}}.

handle_call({register, Pid, HighMemMFA},
            State = #alarms{alertees = Alertess}) ->
    _MRef = erlang:monitor(process, Pid),
    case State#alarms.system_memory_high_watermark of
        true  -> {M, F, A} = HighMemMFA,
                 ok = erlang:apply(M, F, A ++ [Pid, true]);
        false -> ok
    end,
    NewAlertees = dict:store(Pid, HighMemMFA, Alertess),
    {ok, ok, State#alarms{alertees = NewAlertees}};
    
handle_call(_Request, State) ->
    {ok, not_understood, State}.

handle_event({set_alarm, {system_memory_high_watermark, []}}, State) ->
    ok = alert(true, State#alarms.alertees),
    {ok, State#alarms{system_memory_high_watermark = true}};

handle_event({clear_alarm, system_memory_high_watermark}, State) ->
    ok = alert(false, State#alarms.alertees),
    {ok, State#alarms{system_memory_high_watermark = false}};

handle_event(_Event, State) ->
    {ok, State}.

handle_info({'DOWN', _MRef, process, Pid, _Reason},
            State = #alarms{alertees = Alertess}) ->
    {ok, State#alarms{alertees = dict:erase(Pid, Alertess)}};

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

start_memsup(Module) ->
    %% This is based on os_mon:childspec(memsup, true)
    supervisor:start_child(os_mon_sup,
                           {memsup, {Module, start_link, []},
                            permanent, 2000, worker, [Module]}).

alert(Alert, Alertees) ->
    dict:fold(fun (Pid, {M, F, A}, Acc) ->
                      ok = erlang:apply(M, F, A ++ [Pid, Alert]),
                      Acc
              end, ok, Alertees).
