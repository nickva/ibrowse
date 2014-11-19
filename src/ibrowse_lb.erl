%%%-------------------------------------------------------------------
%%% File    : ibrowse_lb.erl
%%% Author  : chandru <chandrashekhar.mullaparthi@t-mobile.co.uk>
%%% Description : 
%%%
%%% Created :  6 Mar 2008 by chandru <chandrashekhar.mullaparthi@t-mobile.co.uk>
%%%-------------------------------------------------------------------

-module(ibrowse_lb).
-author(chandru).
-behaviour(gen_server).

%% External exports
-export([
	 start_link/1,
	 spawn_connection/6,
     stop/1,
     report_connection_down/1,
     report_request_underway/1,
     report_request_complete/1
	]).

%% gen_server callbacks
-export([
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

-record(state, {parent_pid,
                ets_tid,
                host,
                port,
                max_sessions,
                max_pipeline_size,
                proc_state}).

-include("ibrowse.hrl").

%%====================================================================
%% External functions
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

spawn_connection(Lb_pid,
                 Url,
                 Max_sessions,
                 Max_pipeline_size,
                 SSL_options,
                 Process_options)
                 when is_pid(Lb_pid),
                      is_record(Url, url),
                      is_integer(Max_pipeline_size),
                      is_integer(Max_sessions) ->
    gen_server:call(Lb_pid,
		    {spawn_connection, Url, Max_sessions, Max_pipeline_size, SSL_options, Process_options}).

stop(Lb_pid) ->
    case catch gen_server:call(Lb_pid, stop) of
        {'EXIT', {timeout, _}} ->
            exit(Lb_pid, kill);
        ok ->
            ok
    end.

report_connection_down(Tid) ->
    catch ets:delete(Tid, self()).

report_request_underway(Tid) ->
    catch ets:update_counter(Tid, self(), {2, 1, 9999, 9999}).

report_request_complete(Tid) ->
    catch ets:update_counter(Tid, self(), {2, -1, 0, 0}),
    catch ets:update_counter(Tid, self(), {3, -1, 0, 0}).

%%====================================================================
%% Server functions
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init([Host, Port]) ->
    process_flag(trap_exit, true),

    Max_sessions = ibrowse:get_config_value({max_sessions, Host, Port}, 10),
    Max_pipe_sz = ibrowse:get_config_value({max_pipeline_size, Host, Port}, 10),

    put(my_trace_flag, ibrowse_lib:get_trace_status(Host, Port)),
    put(ibrowse_trace_token, ["LB: ", Host, $:, integer_to_list(Port)]),

    {ok, #state{parent_pid = whereis(ibrowse),
                host = Host,
                port = Port,
                max_pipeline_size = Max_pipe_sz,
                max_sessions = Max_sessions}}.

%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call(stop, _From, #state{ets_tid = undefined} = State) ->
    gen_server:reply(_From, ok),
    {stop, normal, State};
handle_call(stop, _From, #state{ets_tid = Tid} = State) ->
    ets:foldl(fun({Pid, _, _}, Acc) ->
                  ibrowse_http_client:stop(Pid),
                  Acc
              end, [], Tid),
    gen_server:reply(_From, ok),
    {stop, normal, State};

handle_call(_, _From, #state{proc_state = shutting_down} = State) ->
    {reply, {error, shutting_down}, State};

handle_call({spawn_connection, Url, Max_sess, Max_pipe, SSL_options, Process_options}, _From, State) ->
    State_1 = maybe_create_ets(State),
    Tid = State_1#state.ets_tid,
    Reply = case ets:info(Tid, size) of
        X when X >= Max_sess ->
            find_best_connection(Tid, Max_pipe);
        _ ->
            Result = {ok, Pid} = ibrowse_http_client:start_link({Tid, Url, SSL_options}, Process_options),
            ets:insert(Tid, {Pid, 0, 0}),
            Result
    end,
    {reply, Reply, State_1#state{max_sessions = Max_sess, max_pipeline_size = Max_pipe}};

handle_call(Request, _From, State) ->
    Reply = {unknown_request, Request},
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({'EXIT', Parent, _Reason}, #state{parent_pid = Parent} = State) ->
    {stop, normal, State};
handle_info({'EXIT', _Pid, _Reason}, #state{ets_tid = undefined} = State) ->
    {noreply, State};
handle_info({'EXIT', Pid, _Reason}, #state{ets_tid = Tid} = State) ->
    ets:match_delete(Tid, {{'_', Pid}, '_'}),
    case ets:info(Tid, size) of
		  0 ->
		      ets:delete(Tid),
			  {noreply, State#state{ets_tid = undefined}, 10000};
		  _ ->
		      {noreply, State}
	      end;

handle_info({trace, Bool}, #state{ets_tid = undefined} = State) ->
    put(my_trace_flag, Bool),
    {noreply, State};
handle_info({trace, Bool}, #state{ets_tid = Tid} = State) ->
    ets:foldl(fun({{_, Pid}, _}, Acc) when is_pid(Pid) ->
		            catch Pid ! {trace, Bool},
		            Acc;
		         (_, Acc) ->
		            Acc
	             end, undefined, Tid),
    put(my_trace_flag, Bool),
    {noreply, State};

handle_info(timeout, State) ->
    %% We can't shutdown the process immediately because a request
    %% might be in flight. So we first remove the entry from the
    %% load balancer named ets table, and then shutdown a couple
    %% of seconds later
    ets:delete(?LOAD_BALANCER_NAMED_TABLE, {State#state.host, State#state.port}),
    erlang:send_after(2000, self(), shutdown),
    {noreply, State#state{proc_state = shutting_down}};

handle_info(shutdown, State) ->
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(_Reason, #state{host = Host, port = Port}) ->
    % Use delete_object instead of delete in case another process for this host/port
    % has been spawned, in which case will be deleting the wrong record because pid won't match.
    ets:delete_object(?LOAD_BALANCER_NAMED_TABLE, #lb_pid{host_port = {Host, Port}, pid = self()}),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
find_best_connection(Tid, Max_pipe) ->
    find_best_connection(ets:first(Tid), Tid, Max_pipe).

find_best_connection('$end_of_table', _, _) ->
    {error, retry_later};
find_best_connection(Pid, Tid, Max_pipe) ->
    case ets:lookup(Tid, Pid) of
        [{Pid, Cur_sz, Speculative_sz}] when Cur_sz < Max_pipe,
                                             Speculative_sz < Max_pipe ->
            case catch ets:update_counter(Tid, Pid, {3, 1, 9999999, 9999999}) of
                {'EXIT', _} ->
                    %% The selected process has shutdown
                    find_best_connection(ets:next(Tid, Pid), Tid, Max_pipe);
                _ ->
                    {ok, Pid}
            end;
         _ ->
            find_best_connection(ets:next(Tid, Pid), Tid, Max_pipe)
    end.

maybe_create_ets(#state{ets_tid = undefined} = State) ->
    Tid = ets:new(?CONNECTIONS_LOCAL_TABLE, [public, ordered_set]),
    State#state{ets_tid = Tid};
maybe_create_ets(State) ->
    State.

