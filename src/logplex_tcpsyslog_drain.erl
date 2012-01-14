%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc
%% @end
%%%-------------------------------------------------------------------
-module(logplex_tcpsyslog_drain).

-behaviour(gen_server).

-include("logplex.hrl").
-include("logplex_logging.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/3
         ,post_msg/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {id :: binary(),
                host :: string() | inet:ip_address(),
                port :: inet:port_number(),
                sock = undefined :: 'undefined' | inet:socket(),
                %% Buffer for messages while disconnected
                buf = logplex_drain_buffer:new() :: logplex_drain_buffer:buf(),
                %% Last time we connected or successfully sent data
                last_good_time :: 'undefined' | erlang:timestamp(),
                %% TCP failures since last_good_time
                failures = 0 :: non_neg_integer(),
                %% Reconnect timer reference
                tref = undefined :: 'undefined' | reference()
               }).

-define(RECONNECT_MSG, reconnect).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec start_link() -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
%% @end
%%--------------------------------------------------------------------
start_link(DrainID, Host, Port) ->
    gen_server:start_link(?MODULE,
                          [#state{id=DrainID,
                                  host=Host,
                                  port=Port}],
                          []).

post_msg(Server, Msg) when is_tuple(Msg) ->
    gen_server:cast(Server, {post, Msg});
post_msg(Server, Msg) when is_binary(Msg) ->
    %% <40>1 2010-11-10T17:16:33-08:00 domU-12-31-39-13-74-02 t.xxx web.1 - - State changed from created to starting
    %% <PriFac>1 Time Host Token Process - - Msg
    case re:run(Msg, "^<(\\d+)>1 (\\S+) \\S+ (\\S+) (\\S+) \\S+ \\S+ (.*)",
                [{capture, all_but_first, binary}]) of
        {match, [PriFac, Time, Source, Ps, Content]} ->
            <<Facility:5, Severity:3>> =
                << (list_to_integer(binary_to_list(PriFac))):8 >>,
            post_msg(Server, {Facility, Severity, Time, Source, Ps, Content});
        _ ->
            {error, bad_syslog_msg}
    end.


%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([State0 = #state{}]) ->
    self() ! ?RECONNECT_MSG,
    {ok, State0}.

%% @private
handle_call(Call, _From, State) ->
    ?WARN("Unexpected call ~p.", [Call]),
    {noreply, State}.

%% @private
handle_cast({post, Msg}, State = #state{sock=undefined,
                                        buf=Buf}) ->
    NewBuf = logplex_drain_buffer:push(Msg, Buf),
    {noreply, State#state{buf=NewBuf}};

handle_cast({post, Msg}, State = #state{id = Token,
                                        sock = S}) ->
    case post(Msg, S, Token) of
        ok ->
            {noreply, tcp_good(State)};
        {error, Reason} ->
            ?ERR("[~p] (~p:~p) Couldn't write syslog message: ~p",
                 [State#state.id, State#state.host, State#state.port,
                  Reason]),
            {noreply, reconnect(tcp_error, State)}
    end;

handle_cast(Msg, State) ->
    ?WARN("Unexpected cast ~p", [Msg]),
    {noreply, State}.

%% @private
handle_info(?RECONNECT_MSG, State = #state{sock = undefined}) ->
    State1 = State#state{tref = undefined},
    case connect(State1) of
        {ok, Sock} ->
            ?INFO("[~s] connected to ~p:~p on try ~p.",
                  [State1#state.id, State1#state.host, State1#state.port,
                   State1#state.failures + 1]),
            {noreply, tcp_good(State1#state{sock=Sock})};
        {error, Reason} ->
            NewState = tcp_bad(State1),
            ?ERR("[~s] Couldn't connect to ~p:~p; ~p"
                 " (try ~p, last success: ~s)",
                 [NewState#state.id, NewState#state.host, NewState#state.port,
                  Reason, NewState#state.failures, time_failed(NewState)]),
            {noreply, reconnect(tcp_error, NewState)}
    end;

handle_info({tcp_closed, S}, State = #state{sock = S}) ->
    {noreply, reconnect(tcp_closed, State#state{sock=undefined})};

handle_info({tcp_error, S, _Reason}, State = #state{sock = S}) ->
    {noreply, reconnect(tcp_error, State#state{sock=undefined})};

handle_info({tcp, S, _Data}, State = #state{sock = S}) ->
    {stop, not_implemented, State};

handle_info(Info, State) ->
    ?WARN("Unexpected info ~p", [Info]),
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec post(logplex_syslog_utils:syslog_msg(), inet:socket(),
           Token::iolist()) ->
                  'ok' |
                  {'error', term()}.
post(Msg, Sock, Token) ->
    SyslogMsg = logplex_syslog_utils:to_msg(Msg, Token),
    Packet = logplex_syslog_utils:frame(SyslogMsg),
    gen_tcp:send(Sock, Packet).

connect(#state{sock = undefined, host=Host, port=Port}) ->
    SendTimeoutS = logplex_app:config(tcp_syslog_send_timeout_secs),
    gen_tcp:connect(Host, Port, [binary
                                 %% We don't expect data, but why not.
                                 ,{active, true}
                                 ,{exit_on_close, true}
                                 ,{keepalive, true}
                                 ,{packet, raw}
                                 ,{reuseaddr, true}
                                 ,{send_timeout,
                                   timer:seconds(SendTimeoutS)}
                                 ,{send_timeout_close, true}
                                 ]).

-spec reconnect('tcp_error' | 'tcp_closed', #state{}) -> #state{}.
reconnect(_Reason, State = #state{failures = F}) ->
    BackOff = erlang:min(logplex_app:config(tcp_syslog_backoff_max),
                         1 bsl F),
    Ref = erlang:send_after(timer:seconds(BackOff), self(), ?RECONNECT_MSG),
    State#state{tref=Ref}.

tcp_good(State = #state{}) ->
    State#state{last_good_time = os:timestamp(),
                failures = 0}.

%% Caller must ensure sock is closed before calling this.
tcp_bad(State = #state{failures = F}) ->
    State#state{failures = F + 1,
                sock = undefined}.

-spec time_failed(#state{}) -> iolist().
time_failed(State = #state{}) ->
    time_failed(os:timestamp(), State).
time_failed(Now, #state{last_good_time=T0})
  when is_tuple(T0) ->
    io_lib:format("~fs ago", [timer:now_diff(Now, T0) / 1000000]);
time_failed(_, #state{last_good_time=undefined}) ->
    "never".

