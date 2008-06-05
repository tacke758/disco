
-module(disco_worker).
-behaviour(gen_server).

-export([start_link/1, start_link_remote/1, remote_worker/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
        terminate/2, code_change/3]).

-record(state, {id, master, eventserv, port, from, jobname, partid, mode, 
                child_pid, node, input, linecount, errlines, results}).

-define(SLAVE_ARGS, "-pa disco/master/ebin +K true").
-define(CMD, "nice -n 19 python2.4 "
                "disco/py/disco_worker.py '~s' '~s' '~s' '~w' ~s").
-define(PORT_OPT, [{line, 100000}, {env, [{"PYTHONPATH", "disco/py"}]}, 
        binary, exit_status, use_stdio, stderr_to_stdout]).

start_link_remote([SlaveName, Master, EventServ, From, JobName, PartID, 
        Mode, Node, Input, Data]) ->

        ets:insert(active_workers, 
                {self(), {From, JobName, Node, Mode, PartID}}),
        NodeAtom = list_to_atom(SlaveName ++ "@" ++ Node),
        error_logger:info_report(["Starting a worker at ", Node, self()]),
        case net_adm:ping(NodeAtom) of
                pong -> ok;
                pang -> slave_master ! {start, self(), Node, ?SLAVE_ARGS},
                        receive
                                slave_started -> ok
                        after 60000 ->
                                exit({data_error, Input})
                        end
        end,
        process_flag(trap_exit, true),
        spawn_link(NodeAtom, disco_worker, remote_worker, [[self(), JobName, Master,
                EventServ, From, PartID, Mode, Node, Input]]),
        receive
                ok -> ok;
                {get_data, Pid} ->
                        error_logger:info_report({"Starting to copy",
                                size(Data), " to ", NodeAtom}),
                        Pid ! {data, Data},
                        error_logger:info_report({"Copy ok" , NodeAtom})
        after 60000 ->
                exit({data_error, Input})
        end,
        wait_for_exit().

remote_worker(Args) ->
        process_flag(trap_exit, true),
        start_link(Args),
        wait_for_exit().

wait_for_exit() ->
        receive
                {'EXIT', _, Reason} -> exit(Reason)
        end.

start_link([Parent, JobName|_] = Args) ->
        error_logger:info_report(["Worker starting at ", node(), Parent]),
        {ok, PCache} = param_cache:start(),
        {ok, ParamsFile} = gen_server:call(PCache,
                {get_params, JobName, Parent}, 60000),
        {ok, Worker} = gen_server:start_link(disco_worker, Args, []),
        ok = gen_server:call(Worker, {start_worker, ParamsFile}),
        Parent ! ok.

init([Id, JobName, Master, EventServ, From, PartID, Mode, Node, Input]) ->
        process_flag(trap_exit, true),
        error_logger:info_report({"Init worker ", JobName, " at ", node()}),
        {ok, #state{id = Id, from = From, jobname = JobName, partid = PartID, 
                    mode = Mode, master = Master, node = Node, input = Input,
                    child_pid = none, eventserv = EventServ, linecount = 0,
                    errlines = [], results = []}}.

handle_call({start_worker, ParamsFile}, _From, State) ->
        Cmd = spawn_cmd(State),
        error_logger:info_report(["Spawn cmd: ", Cmd]),
        Port = open_port({spawn, spawn_cmd(State)}, ?PORT_OPT),
        %Sze = size(State#state.data),
        %port_command(Port, <<Sze:32/little>>),
        port_command(Port, [ParamsFile, "\n"]),
        {reply, ok, State#state{port = Port}, 30000}.

spawn_cmd(#state{input = [Input|_]} = S) when is_list(Input) ->
        InputStr = lists:flatten([[X, 32] || X <- S#state.input]),
        spawn_cmd(S#state{input = InputStr});

spawn_cmd(#state{input = [Input|_]} = S) when is_binary(Input) ->
        InputStr = lists:flatten([[binary_to_list(X), 32] || X <- S#state.input]),
        spawn_cmd(S#state{input = InputStr});

spawn_cmd(#state{jobname = JobName, node = Node, partid = PartID,
                mode = Mode, input = Input}) ->
        lists:flatten(io_lib:fwrite(?CMD,
                [Mode, JobName, Node, PartID, Input])).


strip_timestamp(Msg) when is_binary(Msg) ->
        strip_timestamp(binary_to_list(Msg));
strip_timestamp(Msg) ->
        P = string:chr(Msg, $]),
        if P == 0 ->
                Msg;
        true ->
                string:substr(Msg, P + 2)
        end.

event(S, "WARN", Msg) ->
        event_server:event(S#state.eventserv, S#state.node, S#state.jobname,
                "~s [~s:~B] ~s", ["WARN", S#state.mode, S#state.partid, Msg],
                        [task_failed, S#state.mode]);

event(S, Type, Msg) ->
        event_server:event(S#state.eventserv, S#state.node, S#state.jobname,
                "~s [~s:~B] ~s", [Type, S#state.mode, S#state.partid, Msg], []).

parse_result(L) ->
        [PartID|Url] = string:tokens(L, " "),
        {ok, {list_to_integer(PartID), list_to_binary(Url)}}.

handle_info({_, {data, {eol, <<"**<PID>", Line/binary>>}}}, S) ->
        {noreply, S#state{child_pid = binary_to_list(Line)}}; 

handle_info({_, {data, {eol, <<"**<MSG>", Line/binary>>}}}, S) ->
        event(S, "", strip_timestamp(Line)),
        {noreply, S#state{linecount = S#state.linecount + 1}};

handle_info({_, {data, {eol, <<"**<ERR>", Line/binary>>}}}, S) ->
        M = strip_timestamp(Line),
        event(S, "ERROR", M),
        gen_server:cast(S#state.master,
                {exit_worker, S#state.id, {job_error, M}}),
        {stop, normal, S};

handle_info({_, {data, {eol, <<"**<DAT>", Line/binary>>}}}, S) ->
        M = strip_timestamp(Line),
        event(S, "WARN", M ++ [10] ++ S#state.errlines),
        gen_server:cast(S#state.master, {exit_worker, S#state.id,
                {data_error, {M, S#state.input}}}),
        {stop, normal, S};

handle_info({_, {data, {eol, <<"**<OUT>", Line/binary>>}}}, S) ->
        M = strip_timestamp(Line),
        case catch parse_result(M) of
                {ok, Item} -> {noreply, S#state{results = 
                                       [Item|S#state.results]}};
                _Error -> Err = "Could not parse result line: " ++ Line,
                          event(S, "ERROR", Err),
                          gen_server:cast(S#state.master, 
                                {exit_worker, S#state.id, {job_error, Err}}),
                          {stop, normal, S}
        end;

handle_info({_, {data, {eol, <<"**<END>", Line/binary>>}}}, S) ->
        event(S, "", strip_timestamp(Line)),
        gen_server:cast(S#state.master, 
                {exit_worker, S#state.id, {job_ok, S#state.results}}),
        {stop, normal, S};

handle_info({_, {data, {eol, <<"**", _/binary>> = Line}}}, S) ->
        event(S, "WARN", "Unknown line ID: " ++ binary_to_list(Line)),
        {noreply, S};               

handle_info({_, {data, {eol, Line}}}, S) ->
        {noreply, S#state{errlines = S#state.errlines 
                ++ binary_to_list(Line) ++ [10]}};

handle_info({_, {data, {noeol, Line}}}, S) ->
        event(S, "WARN", "Truncated line: " ++ binary_to_list(Line)),
        {noreply, S};

handle_info({_, {exit_status, _Status}}, #state{linecount = 0} = S) ->
        M =  "Worker didn't start:\n" ++ S#state.errlines,
        event(S, "WARN", M),
        gen_server:cast(S#state.master, {exit_worker, S#state.id,
                {data_error, {M, S#state.input}}}),
        {stop, normal, S};

handle_info({_, {exit_status, _Status}}, S) ->
        M =  "Worker failed. Last words:\n" ++ S#state.errlines,
        event(S, "ERROR", M),
        gen_server:cast(S#state.master,
                {exit_worker, S#state.id, {job_error, M}}),
        {stop, normal, S};
        
handle_info({_, closed}, S) ->
        M = "Worker killed. Last words:\n" ++ S#state.errlines,
        event(S, "ERROR", M),
        gen_server:cast(S#state.master, 
                {exit_worker, S#state.id, {job_error, M}}),
        {stop, normal, S};

handle_info(timeout, #state{linecount = 0} = S) ->
        M = "Worker didn't start in 30 seconds",
        event(S, "WARN", M),
        gen_server:cast(S#state.master, {exit_worker, S#state.id,
                {data_error, {M, S#state.input}}}),
        {stop, normal, S}.

handle_cast(_, State) -> {noreply, State}.

terminate(_Reason, State) -> 
        % Possible bug: If we end up here before knowing child_pid, the
        % child may stay running. However, it may die by itself due to
        % SIGPIPE anyway.

        % Kill child processes of the worker process
        os:cmd("pkill -9 -P " ++ State#state.child_pid),
        % Kill the worker process
        os:cmd("kill -9 " ++ State#state.child_pid).

code_change(_OldVsn, State, _Extra) -> {ok, State}.              



