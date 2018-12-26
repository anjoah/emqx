%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_sys).

-behaviour(gen_server).

-include("emqx.hrl").

-export([start_link/0]).
-export([version/0, uptime/0, datetime/0, sysdescr/0, sys_interval/0]).
-export([info/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-import(emqx_topic, [systop/1]).
-import(emqx_misc, [start_timer/2]).

-record(state, {start_time, heartbeat, ticker, version, sysdescr}).

-define(APP, emqx).
-define(SYS, ?MODULE).

-define(INFO_KEYS, [
    version,  % Broker version
    uptime,   % Broker uptime
    datetime, % Broker local datetime
    sysdescr  % Broker description
]).

-spec(start_link() -> {ok, pid()} | ignore | {error, any()}).
start_link() ->
    gen_server:start_link({local, ?SYS}, ?MODULE, [], []).

%% @doc Get sys version
-spec(version() -> string()).
version() ->
    {ok, Version} = application:get_key(?APP, vsn), Version.

%% @doc Get sys description
-spec(sysdescr() -> string()).
sysdescr() ->
    {ok, Descr} = application:get_key(?APP, description), Descr.

%% @doc Get sys uptime
-spec(uptime() -> string()).
uptime() ->
    gen_server:call(?SYS, uptime).

%% @doc Get sys datetime
-spec(datetime() -> string()).
datetime() ->
    {{Y, M, D}, {H, MM, S}} = calendar:local_time(),
    lists:flatten(
        io_lib:format(
            "~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w", [Y, M, D, H, MM, S])).

%% @doc Get sys interval
-spec(sys_interval() -> pos_integer()).
sys_interval() ->
    application:get_env(?APP, sys_interval, 60000).

%% @doc Get sys info
-spec(info() -> list(tuple())).
info() ->
    [{version,  version()},
     {sysdescr, sysdescr()},
     {uptime,   uptime()},
     {datetime, datetime()}].

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([]) ->
    State = #state{start_time = erlang:timestamp(),
                   version    = iolist_to_binary(version()),
                   sysdescr   = iolist_to_binary(sysdescr())},
    {ok, heartbeat(tick(State))}.

heartbeat(State) ->
    State#state{heartbeat = start_timer(timer:seconds(1), heartbeat)}.
tick(State) ->
    State#state{ticker = start_timer(sys_interval(), tick)}.

handle_call(uptime, _From, State) ->
    {reply, uptime(State), State};

handle_call(Req, _From, State) ->
    emqx_logger:error("[SYS] unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    emqx_logger:error("[SYS] unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({timeout, TRef, heartbeat}, State = #state{heartbeat = TRef}) ->
    publish(uptime, iolist_to_binary(uptime(State))),
    publish(datetime, iolist_to_binary(datetime())),
    {noreply, heartbeat(State)};

handle_info({timeout, TRef, tick}, State = #state{ticker = TRef, version = Version, sysdescr = Descr}) ->
    publish(version, Version),
    publish(sysdescr, Descr),
    publish(brokers, ekka_mnesia:running_nodes()),
    publish(stats, emqx_stats:getstats()),
    publish(metrics, emqx_metrics:all()),
    {noreply, tick(State), hibernate};

handle_info(Info, State) ->
    emqx_logger:error("[SYS] unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{heartbeat = TRef1, ticker = TRef2}) ->
    lists:foreach(fun emqx_misc:cancel_timer/1, [TRef1, TRef2]).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------

uptime(#state{start_time = Ts}) ->
    Secs = timer:now_diff(erlang:timestamp(), Ts) div 1000000,
    lists:flatten(uptime(seconds, Secs)).
uptime(seconds, Secs) when Secs < 60 ->
    [integer_to_list(Secs), " seconds"];
uptime(seconds, Secs) ->
    [uptime(minutes, Secs div 60), integer_to_list(Secs rem 60), " seconds"];
uptime(minutes, M) when M < 60 ->
    [integer_to_list(M), " minutes, "];
uptime(minutes, M) ->
    [uptime(hours, M div 60), integer_to_list(M rem 60), " minutes, "];
uptime(hours, H) when H < 24 ->
    [integer_to_list(H), " hours, "];
uptime(hours, H) ->
    [uptime(days, H div 24), integer_to_list(H rem 24), " hours, "];
uptime(days, D) ->
    [integer_to_list(D), " days,"].

publish(uptime, Uptime) ->
    safe_publish(systop(uptime), Uptime);
publish(datetime, Datetime) ->
    safe_publish(systop(datatype), Datetime);
publish(version, Version) ->
    safe_publish(systop(version), #{retain => true}, Version);
publish(sysdescr, Descr) ->
    safe_publish(systop(sysdescr), #{retain => true}, Descr);
publish(brokers, Nodes) ->
    Payload = string:join([atom_to_list(N) || N <- Nodes], ","),
    safe_publish(<<"$SYS/brokers">>, #{retain => true}, Payload);
publish(stats, Stats) ->
    [safe_publish(systop(lists:concat(['stats/', Stat])), integer_to_binary(Val))
     || {Stat, Val} <- Stats, is_atom(Stat), is_integer(Val)];
publish(metrics, Metrics) ->
    [safe_publish(systop(lists:concat(['metrics/', Metric])), integer_to_binary(Val))
     || {Metric, Val} <- Metrics, is_atom(Metric), is_integer(Val)].

safe_publish(Topic, Payload) ->
    safe_publish(Topic, #{}, Payload).
safe_publish(Topic, Flags, Payload) ->
    emqx_broker:safe_publish(
      emqx_message:set_flags(
        maps:merge(#{sys => true}, Flags),
        emqx_message:make(?SYS, Topic, iolist_to_binary(Payload)))).

