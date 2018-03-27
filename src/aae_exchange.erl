%% -------- Overview ---------
%%
%% The exchange should have the following states
%% - Root Compare
%% - Root Confirm
%% - Branch Compare
%% - Branch Confirm
%% - Clock Compare
%% - Repair
%%
%% Each exchange has a 'blue' list and a 'pink' list.  Each list (blue and 
%% pink) is a set of partitions pertinent to this exchange, with the state
%% to be compared being the merging of all the trees referenced by the list.
%%
%% The lists can be a single item each (for a pairwise exchange), or a 
%% ring-size number of partitions for a coverage query exchange.
%%
%% -------- Root Compare ---------
%%
%% This allows the comparison between the roots of trees.  Each root (with a
%% tree size of large and 4-byte hashes), will be 4KB in size.  The outcome of
%% the comparison should be a set of BranchIDs where the (merged) roots are 
%% showing differences.
%%
%% The Exchange can terminate if the set of differences is empty.  A timeout 
%% should trigger the commencement of the next stage (to provide a pause 
%% between vnode requests).
%%
%% -------- Root Confirm ---------
%%
%% In the next stage the roots are again requested, received and compared.
%% Again a set of branchIDs which differ is created - and the set of 
%% confirmed deltas is the intersection of the sets generated from both root
%% exchanges.
%%
%% The purpose of the confirm stage is to rule out false negative results 
%% related to timing differences in the result of PUTs.
%%
%% The Exchange can terminate if the set of differences is empty.  A timeout 
%% should trigger the commencement of the next stage (to provide a pause 
%% between vnode requests).
%%
%% -------- Branch Compare / Confirm ---------
%%
%% The set of branch ID differences should now be fetched (Compare), and then
%% re-fetched following a timeout (Confirm) to produce a set of SegmentIDs (or
%% tree leaves) that represent differences ebwteen blue and pink, eliminating
%% false negatives related to timing as with the Root Compare and Confirm.
%%
%% Each Branch is 1KB in size.  So if there are more than 16 branches which 
%% have differrences, only 16 should be chosen for the Compare and Confirm to
%% control the volume of network traffic prompted by the exchange.
%%
%% The Exchange can terminate if the set of differences is empty.  A timeout 
%% should trigger the commencement of the next stage (to provide a pause 
%% between vnode requests).
%%
%% -------- Clock Compare ---------
%%
%% The final stage is clock compare.  The clock compare can be done on up to
%% 128 segments across a maximum of 8 BranchIDs.  This is to control the 
%% potential overhead of the comparison and subsequent repairs.  This may mean
%% for empty vnodes o(1000) exchanges may be required to fully recover the 
%% store.  However, in these cases it is likely that handoff and read repair 
%% is already recovering the data so overly-aggressive read repair is 
%% unnecessary.
%%

-module(aae_exchange).

-behaviour(gen_fsm).

-include("include/aae.hrl").

-define(TRANSITION_PAUSE_MS, 1000).
    % A pause between phases - allow queue lengths to change, and avoid
    % generating an excess workload for AAE
-define(CACHE_TIMEOUT_MS, 60000). 
    % 60 seconds (used in fetch root/branches)
-define(SCAN_TIMEOUT_MS, 600000). 
    % 10 minutes (used in fetch clocks)
-define(MAX_RESULTS, 128). 
    % Maximum number of results to request in one round of 

-export([init/1,
            handle_sync_event/4,
            handle_event/3,
            handle_info/3,
            terminate/3,
            code_change/4]).

-export([waiting_all_results/2,
            prepare/2,
            root_compare/2,
            root_confirm/2,
            branch_compare/2,
            branch_confirm/2,
            clock_compare/2]).

-export([start/4]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {root_compare_deltas = [] :: list(),
                root_confirm_deltas = [] :: list(),
                branch_compare_deltas = [] :: list(),
                branch_confirm_deltas = [] :: list(),
                key_deltas = [] :: list(),
                repair_fun,
                reply_fun,
                blue_list = [] :: input_list(),
                pink_list = [] :: input_list(),
                exchange_id :: list(),
                blue_returns :: {integer(), integer()},
                pink_returns :: {integer(), integer()},
                pink_acc,
                blue_acc,
                merge_fun,
                start_time :: erlang:timestamp(),
                pending_state :: atom()
                }).

-type input_list() :: [{fun(), list(tuple())}].
    % The Blue List and the Pink List are made up of:
    % - a SendFun, which should  be a 3-arity function, taking a preflist, 
    % a message and a colour to be used to flag the reply;
    % - a list of preflists, to be used in the SendFun to be filtered by the
    % target.  The Preflist might be {Index, Node} for remote requests or 
    % {Index, Pid} for local requests
-type branch_results() :: list({integer(), binary()}).
    % Results to branch queries are a list mapping Branch ID to the binary for
    % that branch
-type exchange_state() :: #state{}.

%%%============================================================================
%%% API
%%%============================================================================

-spec start(input_list(), input_list(), fun(), fun()) -> {ok, list()}.
%% @doc
%% Start an FSM to manage an exchange and comapre the preflsist in the 
%% BlueList wiht those in the PinkList, using the RepairFun to repair any
%% keys discovered to have inconsistent clocks.  ReplyFun used to reply back
%% to calling client the StateName at termination.
%%
%% Teh replyFun should be a 1 arity function
start(BlueList, PinkList, RepairFun, ReplyFun) ->
    ExchangeID = leveled_codec:generate_uuid(),
    gen_fsm:start(?MODULE, 
                    [BlueList, PinkList, RepairFun, ReplyFun, ExchangeID], 
                    []),
    {ok, ExchangeID}.


%%%============================================================================
%%% gen_fsm callbacks
%%%============================================================================

init([BlueList, PinkList, RepairFun, ReplyFun, ExchangeID]) ->
    leveled_rand:seed(),
    PinkTarget = length(PinkList),
    BlueTarget = length(BlueList),
    State = #state{blue_list = BlueList, 
                    pink_list = PinkList,
                    repair_fun = RepairFun,
                    reply_fun = ReplyFun,
                    exchange_id = ExchangeID,
                    pink_returns = {0, PinkTarget},
                    blue_returns = {0, BlueTarget}},
    aee_util:log("EX001", [ExchangeID, PinkTarget + BlueTarget], logs()),
    {ok, prepare, State, jitter_pause(?TRANSITION_PAUSE_MS)}.

prepare(timeout, State) ->
    ok = send_requests(fetch_root, 
                        State#state.blue_list, State#state.pink_list, 
                        always_blue),
    {next_state, 
        waiting_all_results, 
        State#state{start_time = os:timestamp(),
                    pending_state = root_compare,
                    pink_acc = <<>>,
                    blue_acc = <<>>,
                    merge_fun = fun merge_root/2},
        ?CACHE_TIMEOUT_MS}.

root_compare(timeout, State) ->
    BranchIDs = compare_roots(State#state.blue_acc, State#state.pink_acc),
    trigger_next(fetch_root, 
                    root_confirm, 
                    fun merge_root/2, 
                    <<>>, 
                    length(BranchIDs) == 0, 
                    ?CACHE_TIMEOUT_MS, 
                    State#state{root_compare_deltas = BranchIDs}).

root_confirm(timeout, State) ->
    BranchIDs0 = State#state.root_compare_deltas,
    BranchIDs1 = compare_roots(State#state.blue_acc, State#state.pink_acc),
    BranchIDs = 
        select_ids(intersect_ids(BranchIDs0, BranchIDs1), ?MAX_RESULTS),
    trigger_next({fetch_branches, BranchIDs}, 
                    branch_compare, 
                    fun merge_branches/2, 
                    [], 
                    length(BranchIDs) == 0, 
                    ?CACHE_TIMEOUT_MS, 
                    State#state{root_confirm_deltas = BranchIDs}).

branch_compare(timeout, State) ->
    SegmentIDs = compare_branches(State#state.blue_acc, State#state.pink_acc),
    trigger_next({fetch_branches, State#state.root_confirm_deltas}, 
                    branch_confirm, 
                    fun merge_branches/2, 
                    [],
                    length(SegmentIDs) == 0, 
                    ?CACHE_TIMEOUT_MS, 
                    State#state{branch_compare_deltas = SegmentIDs}).

branch_confirm(timeout, State) ->
    SegmentIDs0 = State#state.branch_compare_deltas,
    SegmentIDs1 = compare_branches(State#state.blue_acc, State#state.pink_acc),
    SegmentIDs = 
        select_ids(intersect_ids(SegmentIDs0, SegmentIDs1), ?MAX_RESULTS),
    trigger_next({fetch_clocks, SegmentIDs}, 
                    clock_compare, 
                    fun merge_clocks/2, 
                    [],
                    length(SegmentIDs) == 0, 
                    ?SCAN_TIMEOUT_MS, 
                    State#state{branch_confirm_deltas = SegmentIDs}).

clock_compare(timeout, State) ->
    RepairKeys = compare_clocks(State#state.blue_acc, State#state.pink_acc),
    RepairFun = State#state.repair_fun,
    aae_util:log("EX004", 
                    [length(RepairKeys), State#state.exchange_id], 
                    logs()),
    RepairFun(RepairKeys),
    {stop, 
        normal, 
        State#state{key_deltas = RepairKeys, pending_state = complete}}.


waiting_all_results({reply, Result, Colour}, State) ->
    {PC, PT} = State#state.pink_returns,
    {BC, BT} = State#state.blue_returns,
    MergeFun = State#state.merge_fun,
    {State0, AllPink, AllBlue} =
        case Colour of  
            pink ->
                PinkAcc = MergeFun(Result, State#state.pink_acc),
                {State#state{pink_returns = {PC + 1, PT}, pink_acc = PinkAcc},
                    PC + 1 == PT, BC == BT};
            blue ->
                BlueAcc = MergeFun(Result, State#state.blue_acc),
                {State#state{blue_returns = {BC + 1, BT}, blue_acc = BlueAcc},
                    PC == PT, BC + 1 == BT}
        end,
    case AllBlue and AllPink of 
        true ->
            {next_state, 
                State0#state.pending_state, 
                State0, 
                jitter_pause(?TRANSITION_PAUSE_MS)};
        false ->
            {next_state, 
                waiting_all_results, 
                State0, 
                set_timeout(State0#state.start_time, ?CACHE_TIMEOUT_MS)}
    end;
waiting_all_results(timeout, State) ->
    {PC, PT} = State#state.pink_returns,
    {BC, BT} = State#state.blue_returns,
    MissingCount = PT + BT - (PC + BC),
    aae_util:log("EX002", 
                    [State#state.pending_state, 
                        MissingCount, 
                        State#state.exchange_id], 
                        logs()),
    {stop, normal, State#state{pending_state = timeout}}.


handle_sync_event(_msg, _From, StateName, State) ->
    {reply, ok, StateName, State}.

handle_event(_Msg, StateName, State) ->
    {next_state, StateName, State}.

handle_info(_Msg, StateName, State) ->
    {next_state, StateName, State}.

terminate(normal, StateName, State) ->
    aae_util:log("EX003", [StateName, State#state.exchange_id], logs()),
    ReplyFun = State#state.reply_fun,
    ReplyFun(StateName).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.


%%%============================================================================
%%% Internal Functions
%%%============================================================================

-spec trigger_next(any(), atom(), fun(), any(), boolean(), 
                                        integer(), exchange_state()) -> any().
%% @doc
%% Trigger the next request 
trigger_next(NextRequest, PendingStateName, MergeFun, InitAcc, StopTest, 
                                                        Timeout, LoopState) ->
    case StopTest of 
        true ->
            {stop, normal, LoopState};
        false ->
            ok = send_requests(NextRequest, 
                                LoopState#state.blue_list, 
                                LoopState#state.pink_list, 
                                always_blue),
            {next_state,
                waiting_all_results,
                LoopState#state{start_time = os:timestamp(),
                                pending_state = PendingStateName,
                                pink_acc = InitAcc,
                                blue_acc = InitAcc,
                                merge_fun = MergeFun,
                                pink_returns = 
                                    reset(LoopState#state.pink_returns),
                                blue_returns = 
                                    reset(LoopState#state.blue_returns)},
                Timeout}
    end.


-spec set_timeout(erlang:timestamp(), pos_integer()) -> integer().
%% @doc
%% Set the timeout in a given state based on the time the state was commenced
set_timeout(StartTime, Timeout) ->
    max(0, Timeout - timer:now_diff(os:timestamp(), StartTime) div 1000).

-spec send_requests(any(), list(tuple()), list(tuple()), 
                                            always_blue|always_pink) -> ok.
%% @doc
%% Alternate between sending requests to items on the blue and pink list
send_requests(_Msg, [], [], _Always) ->
    ok;
send_requests(Msg, [{SendFun, Preflists}|Rest], PinkList, always_blue) ->
    SendFun(Msg, Preflists, blue),
    case length(PinkList) > 0 of
        true ->
            send_requests(Msg, Rest, PinkList, always_pink);
        false ->
            send_requests(Msg, Rest, PinkList, always_blue)
    end;
send_requests(Msg, BlueList, [{SendFun, Preflists}|Rest], always_pink) ->
    SendFun(Msg, Preflists, pink),
    case length(BlueList) > 0 of
        true ->
            send_requests(Msg, BlueList, Rest, always_blue);
        false ->
            send_requests(Msg, BlueList, Rest, always_pink)
    end.


-spec merge_root(binary(), binary()) -> binary().
%% @doc
%% Merge an individual result for a set of preflists into the accumulated 
%% binary for the tree root
merge_root(ResultBin, RootAccBin) ->
    leveled_tictac:merge_binaries(ResultBin, RootAccBin).

-spec merge_branches(branch_results(), branch_results()) -> branch_results().
%% @doc
%% Branches should be returned as a list of {BranchID, BranchBin} pairs.  For 
%% each branch in a result, merge into the accumulator.
merge_branches([], BranchAccL) ->
    BranchAccL;
merge_branches([{BranchID, BranchBin}|Rest], BranchAccL) ->
    case lists:keyfind(BranchID, 1, BranchAccL) of
        false ->
            % First repsonse has an empty accumulator
            merge_branches(Rest, [{BranchID, BranchBin}|BranchAccL]);
        {BranchID, BinAcc} ->
            BinAcc0 = leveled_tictac:merge_binaries(BranchBin, BinAcc),
            lists:keyreplace(BranchID, 1, BranchAccL, {BranchID, BinAcc0})
    end.

-spec merge_clocks(list(tuple()), list(tuple())) -> list(tuple()).
%% @doc
%% Accumulate keys and clocks returned in the segment query, outputting a 
%% sorted list of keys and clocks.
merge_clocks(KeyClockL, KeyClockLAcc) ->
    lists:merge(lists:usort(KeyClockL), KeyClockLAcc).


-spec compare_roots(binary(), binary()) -> list(integer()).
%% @doc
%% Compare the roots of two trees (i.e. the Pink and Blue root), and return a 
%% list of branch IDs which are mismatched.
compare_roots(BlueRoot, PinkRoot) ->
    leveled_tictac:find_dirtysegments(BlueRoot, PinkRoot).

-spec compare_branches(branch_results(), branch_results()) -> list(integer()).
%% @doc
%% Compare two sets of branches , and return a list of segment IDs which are 
%% mismatched
compare_branches(BlueBranches, PinkBranches) ->
    FoldFun =
        fun(Idx, Acc) ->
            {BranchID, BlueBranch} = lists:nth(Idx, BlueBranches),
            {BranchID, PinkBranch} = lists:keyfind(BranchID, 1, PinkBranches),
            DirtySegs =
                leveled_tictac:find_dirtysegments(BlueBranch, PinkBranch),
            lists:map(fun(S) -> 
                            leveled_tictac:join_segment(BranchID, S) 
                        end,
                        DirtySegs) ++ Acc
        end,
    lists:foldl(FoldFun, [], lists:seq(1, length(BlueBranches))).

-spec compare_clocks(list(tuple()), list(tuple())) -> list(tuple()).
%% @doc
%% Find the differences between the lists 
compare_clocks(BlueList, PinkList) ->
    BlueExcess = lists:subtract(BlueList, PinkList),
    PinkExcess = lists:subtract(PinkList, BlueList),
    lists:ukeymerge(1, BlueExcess, PinkExcess).

-spec intersect_ids(list(integer()), list(integer())) -> list(integer()).
%% @doc
%% Provide the intersection of two lists of integer IDs
intersect_ids(IDs0, IDs1) ->
    lists:filter(fun(ID) -> lists:member(ID, IDs1) end, IDs0).


-spec select_ids(list(integer()), pos_integer()) -> list(integer()).
%% @doc
%% Select a cluster of IDs if the list of IDs is smaller than the maximum 
%% output size.  The lookup based on these IDs will be segment based, so it 
%% is expected that the tightest clustering will yield the most efficient 
%% results. 
select_ids(IDList, MaxOutput) ->
    FoldFun =
        fun(Idx, {BestIdx, MinOutput}) ->
            Space = lists:nth(MaxOutput + Idx - 1, IDList) 
                        - lists:nth(Idx, IDList),
            case Space < MinOutput of 
                true ->
                    {Idx, Space};
                false ->
                    {BestIdx, MinOutput}
            end
        end,
    case length(IDList) > MaxOutput of 
        true ->
            {BestSliceStart, _Score} = 
                lists:foldl(FoldFun, 
                            {0, infinity}, 
                            lists:seq(1, 1 + length(IDList) - MaxOutput)),
            lists:sublist(IDList, BestSliceStart, MaxOutput);
        false ->
            IDList
    end.
    
-spec jitter_pause(pos_integer()) -> pos_integer().
%% @doc
%% Jitter a pause, so if multiple FSMs started at once, they don't all use
%% the network at the same time
jitter_pause(Timeout) ->
    leveled_rand:uniform(Timeout) + Timeout div 2.


-spec reset({pos_integer(), pos_integer()}) 
                                        -> {non_neg_integer(), pos_integer()}.
%% @doc
%% Rest the count back to 0
reset({Target, Target}) -> {0, Target}. 

%%%============================================================================
%%% log definitions
%%%============================================================================

-spec logs() -> list(tuple()).
%% @doc
%% Define log lines for this module
logs() ->
    [{"EX001", 
            {info, "Exchange id=~s with target_count=~w expected"}},
        {"EX002",
            {error, "Timeout with pending_state=~w and missing_count=~w" 
                        ++ " for exchange id=~s"}},
        {"EX003",
            {info, "Normal exit at pending_state=~w for exchange id=~s"}},
        {"EX004",
            {info, "Exchange id =~s led to prompting of repair_count=~w"}}
        ].


%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).

select_id_test() ->
    L0 = [1, 2, 3],
    ?assertMatch(L0, select_ids(L0, 3)),
    L1 = [1, 2, 3, 5],
    ?assertMatch(L0, select_ids(L1, 3)),
    L2 = [1, 2, 3, 5, 6, 7, 8],
    ?assertMatch(L0, select_ids(L2, 3)),
    ?assertMatch([5, 6, 7, 8], select_ids(L2, 4)),
    ?assertMatch(L0, select_ids(intersect_ids(L1, L2), 3)).

-endif.