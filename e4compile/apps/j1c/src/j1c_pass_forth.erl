%%% @doc J1-like forth to binary compiler adjusted for Erlang needs with
%%% added types, literals etc.

-module(j1c_pass_forth).

%% API
-export([compile/2]).

-include_lib("e4c/include/forth.hrl").
-include_lib("e4c/include/e4c.hrl").
-include_lib("j1c/include/j1.hrl").

compile(ModuleName, Input) ->
    Prog0 = #j1prog{mod = ModuleName},
    % Module name should always be #0
    {Prog0A, _} = atom_index_or_create(Prog0, atom_to_binary(ModuleName, utf8)),

    Prog1 = compile2(Prog0A, preprocess(Input, [])),

    %% Print the output
    Output = lists:reverse(Prog1#j1prog.output),
    Prog2 = Prog1#j1prog{output=Output},
    %Patched = apply_patches(Output, Prog1#j1prog.patch_table, []),
    %Prog2 = Prog1#j1prog{output=Patched},

%%    io:format("~s~n~s~n", [color:redb("J1C PASS 1"),
%%                           format_j1c_pass1(Prog2, 0, Patched, [])]),
    Prog2.

preprocess([], Acc) -> lists:flatten(lists:reverse(Acc));
preprocess([?F_LIT_ATOM, Word | T], Acc) ->
    preprocess(T, [#k_atom{val=Word} | Acc]);
preprocess([H | T], Acc) -> preprocess(T, [H | Acc]).

compile2(Prog0 = #j1prog{}, []) -> Prog0;

%% --- special words ---

compile2(Prog0 = #j1prog{}, [#f_export{fn=Fn, arity=Arity} | Tail]) ->
    Prog1 = prog_add_export(Prog0, Fn, Arity),
    compile2(Prog1, Tail);

%% NEW FUNCTION -- : MFA ... ;
compile2(Prog0 = #j1prog{}, [<<":">>, ?F_LIT_FUNA, Fn, Arity | Tail]) ->
    Prog1 = prog_add_word(Prog0, #k_local{name=Fn, arity=Arity}),
    compile2(Prog1, Tail);

compile2(Prog0 = #j1prog{}, [<<":MODULE">>, Name | Tail]) ->
    compile2(Prog0#j1prog{mod=Name}, Tail);
compile2(Prog0 = #j1prog{}, [<<":">>, Name | Tail]) ->
    Prog1 = prog_add_word(Prog0, Name),
    compile2(Prog1, Tail);
compile2(Prog0 = #j1prog{}, [<<":NIF">>, Name, Index0 | Tail]) ->
    Index1 = binary_to_integer(Index0),
    Prog1 = prog_add_nif(Prog0, Name, Index1),
    compile2(Prog1, Tail);

%%compile2(Prog0 = #j1prog{}, [<<";">> | Tail]) ->
%%    Prog1 = emit_alu(Prog0, #alu{op=0, rpc=1, ds=2}),
%%    compile2(Prog1, Tail);
%%compile2(Prog0 = #j1prog{}, [?F_RET | Tail]) ->
%%    Prog1 = emit_alu(Prog0, #alu{op=0, rpc=1, ds=2}),
%%    compile2(Prog1, Tail);

%% --- literals ---
%%compile2(Prog0 = #j1prog{}, [#k_atom{val=Word} | Tail]) -> % atom follows
%%    Prog1 = emit_lit(Prog0, atom, Word),
%%    compile2(Prog1, Tail);
%%compile2(Prog0 = #j1prog{}, [#k_literal{val=L} | Tail]) -> % a preparsed literal
%%    Prog1 = emit_lit(Prog0, arbitrary, L),
%%    compile2(Prog1, Tail);

%% --- Conditions ---
compile2(Prog0 = #j1prog{}, [<<"IF">> | Tail]) ->
    {F, Prog1} = begin_condition(Prog0),
    Prog2 = emit(Prog1, #j1jump{label = F, condition = z}),
    compile2(Prog2, Tail);
compile2(Prog0 = #j1prog{}, [<<"UNLESS">> | Tail]) ->
    compile2(Prog0, [<<"INVERT">>, <<"IF">> | Tail]);
compile2(Prog0 = #j1prog{}, [<<"THEN">> | Tail]) ->
    Prog1 = cond_update_label(Prog0, 0),
    compile2(Prog1, Tail);
compile2(Prog0 = #j1prog{}, [<<"ELSE">> | Tail]) ->
    %% combine IF and THEN - update a label address for previous IF and create
    %% a new label and jump instruction to jump over the code after ELSE
    %% IF[] ----------------> ELSE -------------> THEN[upd patchtable]
    %% #j1patch is emitted here  |                  |
    %% with conditional jump     |                  |
    %%                   patchtable is updated here |
    %%                   jump is emitted here       |
    %%                                             patchtable is updated here
    %%
    %% Pop from the cond table, update label id with current PC
    Prog1 = cond_update_label(Prog0, 1),
    %% Make new label and create a jump to it
    {F, Prog2} = begin_condition(Prog1),
    Prog2 = emit(Prog1, #j1jump{label = F}),
    %% Wait for THEN and do the same again to finalize the condition
    compile2(Prog2, Tail);

%% --- Loops (started with a BEGIN) ---
compile2(Prog0 = #j1prog{}, [<<"BEGIN">> | Tail]) ->
    {_F, Prog1} = begin_loop(Prog0),
    compile2(Prog1, Tail);
compile2(Prog0 = #j1prog{}, [<<"AGAIN">> | Tail]) -> % endless loop
    %% Just emit jump back to the BEGIN instruction
    {Begin, Prog1} = end_loop(Prog0),
    Prog2 = emit(Prog1, #j1jump{label = Begin}),
    compile2(Prog2, Tail);
compile2(Prog0 = #j1prog{}, [<<"UNTIL">> | Tail]) -> % conditional if-zero loop
    %% Emit conditional jump back to the BEGIN instruction
    {Begin, Prog1} = end_loop(Prog0),
    Prog2 = emit(Prog1, #j1jump{label = Begin}),
    compile2(Prog2, Tail);

%% TODO: EQU, maybe VAR, ARR?

compile2(Prog0 = #j1prog{}, [?F_LIT_MFA, M, F, A | Tail]) -> % mfa literal
    Prog1 = emit_lit(Prog0, mfa, {M, F, A}),
    compile2(Prog1, Tail);
compile2(Prog0 = #j1prog{}, [?F_LIT_FUNA, Fn, Arity | Tail]) ->
    Prog1 = emit_lit(Prog0, funarity, {Fn, Arity}),
    compile2(Prog1, Tail);

%% Nothing else worked, look for the word in our dictionaries and base words,
%% maybe it is a literal, too
compile2(Prog0 = #j1prog{}, [Word | Tail]) ->
    compile2(emit(Prog0, [Word]), Tail).
%%    %% Possibly a word, try resolve
%%    Prog1 = case prog_find_word(Prog0, Word) of
%%                not_found -> emit_base_word(Prog0, Word);
%%                Index -> emit_call(Prog0, Index)
%%            end,
%%    compile2(Prog1, Tail).

%%compile2(_Prog, [Other | _]) ->
%%    ?COMPILE_ERROR("E4 J1C: unknown op ~p", [Other]).

%%j1_jump(Label) ->
%%    %% Add extra 16 bits to label width. This will be replaced by an offset
%%    %% in the VM during load time
%%    <<?J1INSTR_JUMP:?J1INSTR_WIDTH, Label:(?J1OP_INDEX_WIDTH + 16)/big>>.
%%
%%j1_cond_jump(Label) ->
%%    %% Add extra 16 bits to label width. This will be replaced by an offset
%%    %% in the VM during load time
%%    <<?J1INSTR_JUMP_COND:?J1INSTR_WIDTH, Label:(?J1OP_INDEX_WIDTH + 16)/big>>.

%% @doc Create a label with current PC, and push its id onto condition stack.
%% The value for the label will be updated once ELSE or THEN is reached
-spec begin_condition(j1prog()) -> {j1label(), j1prog()}.
begin_condition(Prog0 = #j1prog{condstack=CondStack}) ->
    {F, Prog1} = create_label(Prog0),
    {F, Prog1#j1prog{condstack=[F | CondStack]}}.

%% @doc Creates a label with current PC and puts its id onto loop stack.
%% The label will be used for jump once UNTIL or AGAIN is reached
-spec begin_loop(j1prog()) -> {j1label(), j1prog()}.
begin_loop(Prog0 = #j1prog{loopstack=LoopStack}) ->
    {F, Prog1} = create_label(Prog0),
    {F, Prog1#j1prog{loopstack=[F | LoopStack]}}.

-spec end_condition(j1prog()) -> {integer(), j1prog()}.
end_condition(#j1prog{condstack=[]}) ->
    ?COMPILE_ERROR("E4 J1C: ELSE or THEN have no matching IF");
end_condition(Prog0 = #j1prog{condstack=[CSTop | CondStack]}) ->
    {CSTop, Prog0#j1prog{condstack=CondStack}}.

-spec end_loop(j1prog()) -> {integer(), j1prog()}.
end_loop(#j1prog{loopstack=[]}) ->
    ?COMPILE_ERROR("E4 J1C: AGAIN or UNTIL have no matching BEGIN");
end_loop(Prog0 = #j1prog{loopstack=[LSTop | LoopStack]}) ->
    {LSTop, Prog0#j1prog{loopstack=LoopStack}}.

%% @ doc Push PC onto cond stack + write j1patch{id=PC} in the output
%%emit_patch(Prog0 = #j1prog{pc=PC}, Op) ->
%%    Prog1 = prog_cond_push(Prog0),
%%    emit(Prog1, #j1patch{op=Op, id=PC}).

%% @doc Create a new label id to be placed in code (resolved at load time)
create_label(Prog0 = #j1prog{label_id = F0}) ->
    Prog1 = emit(Prog0, #j1label{label = F0}),
    {F0, Prog1#j1prog{
        label_id = F0 + 1
        %labels = [{F0, PC} | Labels]
    }}.

%% @ doc Pop a label id from the cond stack and update #j1prog.labels with
%% the PC+Offset value.
cond_update_label(Prog0 = #j1prog{},
                  Offset) ->
    {F, Prog1} = end_condition(Prog0),
    emit(Prog1, #j1label{label = F}).
%%    Prog1#j1prog{labels = orddict:store(F, PC + Offset, Labels)}.

prog_add_export(Prog0 = #j1prog{exports = Expt},
                Fun,
                Arity) ->
    {Prog1, _} = atom_index_or_create(Prog0, Fun),
    Expt1 = [{Fun, Arity} | Expt],
    Prog1#j1prog{exports = Expt1}.

as_int(I) when is_binary(I) -> binary_to_integer(I).

%% @doc Adds a word to the dictionary, records current program length (program
%% counter position) as the word address.
-spec prog_add_word(j1prog(), FA :: k_local() | binary()) -> j1prog().
prog_add_word(Prog0 = #j1prog{dict=Dict},
              #k_local{name=#k_atom{val=Fn}, arity=Arity}) ->
    {F, Prog1} = create_label(Prog0),
    Dict1 = orddict:store({Fn, as_int(Arity)}, F, Dict),
    {Prog2, _} = atom_index_or_create(Prog1, Fn),
    Prog2#j1prog{dict=Dict1};
prog_add_word(Prog0 = #j1prog{dict=Dict}, Word) when is_binary(Word) ->
    {F, Prog1} = create_label(Prog0),
    Dict1 = orddict:store(Word, F, Dict),
    {Prog2, _} = atom_index_or_create(Prog1, Word),
    Prog2#j1prog{dict=Dict1}.

%% @doc Adds a NIF name to the dictionary, does not register any other data
%% just marks the name as existing.
-spec prog_add_nif(j1prog(), Word :: binary(), Index :: neg_integer())
                  -> j1prog().
prog_add_nif(#j1prog{}, Word, Index) when Index >= 0 ->
    ?COMPILE_ERROR("E4 J1C: Bad NIF index ~p in :NIF directive ~p",
                   [Index, Word]);
prog_add_nif(Prog0 = #j1prog{dict_nif=Dict}, Word, Index) ->
    Dict1 = orddict:store(Word, Index, Dict),
    Prog0#j1prog{dict_nif=Dict1}.


%%%% @doc Looks up a word in the dictionary, returns its address or 'not_found'
%%-spec prog_find_word(j1prog(), forth_word()) -> integer() | not_found.
%%prog_find_word(#j1prog{dict_nif=Nifs, dict=Dict}, Word) ->
%%    case orddict:find(Word, Nifs) of
%%        {ok, Index} -> Index; % nifs have negative indexes
%%        error ->
%%            case orddict:find(Word, Dict) of
%%                {ok, Index} -> Index;
%%                error -> not_found
%%            end
%%    end.
%%
%%%% @doc Emits a CALL instruction with Index (signed) into the code.
%%%% Negative indices point to NIF functions
%%emit_call(Prog0 = #j1prog{}, Index)
%%    when Index < 1 bsl ?J1OP_INDEX_WIDTH, Index > -(1 bsl ?J1OP_INDEX_WIDTH)
%%    ->
%%    emit(Prog0, <<?J1INSTR_CALL:?J1INSTR_WIDTH,
%%                  Index:?J1OP_INDEX_WIDTH/signed>>).

%%emit(Prog0 = #j1prog{output=Out, pc=PC}, #j1patch{}=Patch) ->
%%    Prog0#j1prog{output=[Patch | Out],
%%                 pc=PC + 1};
emit(Prog0 = #j1prog{output=Out, pc=PC}, IOList) ->
    Prog0#j1prog{output=[IOList | Out],
                 pc=PC + 1}.

%%-spec emit_alu(j1prog(), alu() | [alu()]) -> j1prog().
%%emit_alu(Prog = #j1prog{}, ALUList) when is_list(ALUList) ->
%%    lists:foldl(fun(ALU, P) -> emit_alu(P, ALU) end, Prog, ALUList);
%%emit_alu(Prog = #j1prog{}, ALU = #alu{ds=-1}) ->
%%    emit_alu(Prog, ALU#alu{ds=2});
%%emit_alu(Prog = #j1prog{}, ALU = #alu{rs=-1}) ->
%%    emit_alu(Prog, ALU#alu{rs=2});
%%emit_alu(Prog = #j1prog{}, #alu{op=Op0, tn=TN, rpc=RPC, tr=TR, nti=NTI,
%%                                ds=Ds, rs=Rs}) ->
%%    %% Operation consists of 4 4-bit nibbles, tag goes first (3 bits) followed
%%    %% by the RPC flag, then goes operation, then combination of TN,TR,NTI
%%    %% flags and 1 unused bit, and then Ds/Rs 2 bits each
%%    %%
%%    %% 15 14 13 12 | 11 10 09 08 | 07 06 05 04 | 03 02 01 00 |
%%    %% InstrTag RPC| Op--------- | TN TR NTI ? | DS--- RS--- |l
%%    %%
%%    Op1 = <<?J1INSTR_ALU:3, RPC:1,
%%            Op0:4,
%%            TN:1, TR:1, NTI:1, 0:1,
%%            Rs:2, Ds:2>>,
%%    emit(Prog, Op1).
%%
%%-spec emit_base_word(j1prog(), binary() | f_comment()) -> j1prog().
%%emit_base_word(Prog0, <<"+">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T_PLUS_N, ds=-1});
%%emit_base_word(Prog0, <<"XOR">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T_XOR_N, ds=-1});
%%emit_base_word(Prog0, <<"AND">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T_AND_N, ds=-1});
%%emit_base_word(Prog0, <<"OR">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T_OR_N, ds=-1});
%%
%%emit_base_word(Prog0, <<"INVERT">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_INVERT_T});
%%
%%emit_base_word(Prog0, <<"=">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_N_EQ_T, ds=-1});
%%emit_base_word(Prog0, <<"<">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_N_LESS_T, ds=-1});
%%emit_base_word(Prog0, <<"U<">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_N_UNSIGNED_LESS_T, ds=-1});
%%
%%emit_base_word(Prog0, <<"SWAP">>) -> % swap data stack top 2 elements
%%    emit_alu(Prog0, #alu{op=?J1OP_N, tn=1});
%%emit_base_word(Prog0, <<"DUP">>) -> % clone data stack top
%%    emit_alu(Prog0, #alu{op=?J1OP_T, tn=1});
%%emit_base_word(Prog0, <<"DROP">>) -> % drop top on data stack
%%    emit_alu(Prog0, #alu{op=?J1OP_N, ds=-1});
%%emit_base_word(Prog0, <<"OVER">>) -> % clone second on data stack
%%    emit_alu(Prog0, #alu{op=?J1OP_N, tn=1, ds=1});
%%emit_base_word(Prog0, <<"NIP">>) -> % drops second on data stack
%%    emit_alu(Prog0, #alu{op=?J1OP_T, ds=-1});
%%
%%emit_base_word(Prog0, <<">R">>) -> % place onto Rstack
%%    emit_alu(Prog0, #alu{op=?J1OP_N, tr=1, ds=-1, rs=1});
%%emit_base_word(Prog0, <<"R>">>) -> % take from Rstack
%%    emit_alu(Prog0, #alu{op=?J1OP_R, tn=1, ds=1, rs=-1});
%%emit_base_word(Prog0, <<"R@">>) -> % read Rstack top
%%    emit_alu(Prog0, #alu{op=?J1OP_R, tn=1, ds=1, rs=0});
%%emit_base_word(Prog0, <<"@">>) -> % read address
%%    emit_alu(Prog0, #alu{op=?J1OP_INDEX_T});
%%emit_base_word(Prog0, <<"!">>) -> % write address
%%    emit_alu(Prog0, [
%%        #alu{op=?J1OP_T, ds=-1},
%%        #alu{op=?J1OP_N, ds=-1}
%%    ]);
%%
%%emit_base_word(Prog0, <<"DSP">>) -> % get stack depth
%%    emit_alu(Prog0, #alu{op=?J1OP_DEPTH, tn=1, ds=1});
%%
%%emit_base_word(Prog0, <<"LSHIFT">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_N_LSHIFT_T, ds=-1});
%%emit_base_word(Prog0, <<"RSHIFT">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_N_RSHIFT_T, ds=-1});
%%emit_base_word(Prog0, <<"1-">>) -> % decrement stack top
%%    emit_alu(Prog0, #alu{op=?J1OP_T_MINUS_1});
%%emit_base_word(Prog0, <<"2R>">>) ->
%%    emit_alu(Prog0, [
%%        #alu{op=?J1OP_R, tn=1, ds=1, rs=-1},
%%        #alu{op=?J1OP_R, tn=1, ds=1, rs=-1},
%%        #alu{op=?J1OP_N, tn=1}
%%    ]);
%%emit_base_word(Prog0, <<"2>R">>) ->
%%    emit_alu(Prog0, [
%%        #alu{op=?J1OP_N, tn=1},
%%        #alu{op=?J1OP_N, tr=1, ds=-1, rs=1},
%%        #alu{op=?J1OP_N, tr=1, ds=-1, rs=1}
%%    ]);
%%emit_base_word(Prog0, <<"2R@">>) ->
%%    emit_alu(Prog0, [
%%        #alu{op=?J1OP_R, tn=1, ds=1, rs=-1},
%%        #alu{op=?J1OP_R, tn=1, ds=1, rs=-1},
%%        #alu{op=?J1OP_N, tn=1, ds=1},
%%        #alu{op=?J1OP_N, tn=1, ds=1},
%%        #alu{op=?J1OP_N, tr=1, ds=-1, rs=1},
%%        #alu{op=?J1OP_N, tr=1, ds=-1, rs=1},
%%        #alu{op=?J1OP_N, tn=1}
%%    ]);
%%emit_base_word(Prog0, <<"DUP@">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_INDEX_T, tn=1, ds=1});
%%emit_base_word(Prog0, <<"DUP>R">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T, tr=1, rs=1});
%%emit_base_word(Prog0, <<"2DUPXOR">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T_XOR_N, tn=1, ds=1});
%%emit_base_word(Prog0, <<"2DUP=">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_N_EQ_T, tn=1, ds=1});
%%emit_base_word(Prog0, <<"!NIP">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T, nti=1, ds=-1});
%%emit_base_word(Prog0, <<"2DUP!">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T, nti=1});
%%emit_base_word(Prog0, <<"UP1">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T, ds=1});
%%emit_base_word(Prog0, <<"DOWN1">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T, ds=-1});
%%emit_base_word(Prog0, <<"COPY">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_N});
%%
%%emit_base_word(Prog0, <<"NOOP">>) ->
%%    emit_alu(Prog0, #alu{op=?J1OP_T});
%%
%%%%emit_base_word(Prog0, Integer) when is_integer(Integer) ->
%%%%    emit_lit(Prog0, integer, Integer);
%%emit_base_word(Prog0, #f_comment{}) -> Prog0; % skip comments
%%emit_base_word(Prog0, <<First:8, _/binary>> = Word)
%%    when First >= $0 andalso First =< $9 orelse First =:= $-
%%    ->
%%    case (catch binary_to_integer(Word)) of
%%        X when is_integer(X) ->
%%            emit_lit(Prog0, integer, X);
%%        {'EXIT', {badarg, _}} ->
%%            ?COMPILE_ERROR("E4 J1C Pass1: word is not defined: ~s",
%%                           [?COLOR_TERM(red, Word)])
%%    end;
%%emit_base_word(_Prog, Word) ->
%%    ?COMPILE_ERROR("E4 J1C Pass1: word is not defined: ~s",
%%                   [?COLOR_TERM(red, Word)]).
%%

%% @doc Looks up an atom in the atom table, returns its paired value or creates
%% a new atom, assigns it next available index and returns it
atom_index_or_create(Prog0 = #j1prog{atom_id=AtomId, atoms=Atoms}, Value)
    when is_binary(Value) ->
    case orddict:find(Value, Atoms) of
        error ->
            Prog1 = Prog0#j1prog{
                atom_id=AtomId + 1,
                atoms=orddict:store(Value, AtomId, Atoms)
            },
            {Prog1, AtomId};
        {ok, Existing} ->
            {Prog0, Existing}
    end.
%%
%%%% @doc Looks up a literal in the literal table, returns its paired value or
%%%% creates a new literal, assigns it next available index and returns it
%%literal_index_or_create(Prog0 = #j1prog{lit_id=LitId, literals=Literals},
%%                        Value) ->
%%    case orddict:find(Value, Literals) of
%%        error ->
%%            Prog1 = Prog0#j1prog{
%%                lit_id=LitId + 1,
%%                literals=orddict:store(Value, LitId, Literals)
%%            },
%%            {Prog1, LitId};
%%        {ok, Existing} ->
%%            {Prog0, Existing}
%%    end.

emit_lit(Prog0 = #j1prog{}, atom, Word) ->
    {Prog1, AIndex} = atom_index_or_create(Prog0, Word),
    emit(Prog1, <<1:1, AIndex:?J1_LITERAL_BITS>>);
emit_lit(Prog0 = #j1prog{}, integer, X) ->
    emit(Prog0, <<1:1, X:?J1_LITERAL_BITS/signed>>);
emit_lit(Prog0 = #j1prog{}, mfa, {M, F, A}) ->
    M1 = eval(M),
    F1 = eval(F),
    A1 = erlang:binary_to_integer(A),
    {Prog1, LIndex} = literal_index_or_create(Prog0, {'$MFA', M1, F1, A1}),
    emit(Prog1, <<1:1, LIndex:?J1_LITERAL_BITS>>);
emit_lit(Prog0 = #j1prog{}, funarity, {F, A}) ->
    F1 = eval(F),
    A1 = erlang:binary_to_integer(A),
    {Prog1, LIndex} = literal_index_or_create(Prog0, {'$FA', F1, A1}),
    emit(Prog1, <<1:1, LIndex:?J1_LITERAL_BITS>>);
emit_lit(Prog0 = #j1prog{}, arbitrary, Lit) ->
    {Prog1, LIndex} = literal_index_or_create(Prog0, Lit),
    emit(Prog1, <<1:1, LIndex:?J1_LITERAL_BITS>>).

eval(#k_atom{val=A}) -> erlang:binary_to_atom(A, utf8).

%%format_j1c_pass1(_Prog, _Pc, [], Accum) -> lists:reverse(Accum);
%%format_j1c_pass1(Prog, Pc, [H | Tail], Accum) ->
%%    format_j1c_pass1(Prog, Pc+1, Tail, [
%%        format_j1c_op(Prog, H),
%%        io_lib:format("~4.16.0B: ", [Pc]) | Accum
%%    ]).
%%
%%%%format_j1c_op(Prog, #j1patch{op=Op, id=Id}) ->
%%%%    io_lib:format("~s id=~p (~s)~n", [color:yellowb("PATCH"), Id,
%%%%                                      format_j1c_op(Prog, Op)]);
%%format_j1c_op(_Prog, <<1:1, Lit:(?J1BITS-1)/signed>>) ->
%%    io_lib:format("~s ~p~n", [color:blueb("LIT"), Lit]);
%%format_j1c_op(Prog, <<?J1INSTR_CALL:?J1INSTR_WIDTH,
%%                       Addr:?J1OP_INDEX_WIDTH/signed>>) ->
%%    io_lib:format("~s ~s~n", [color:green("CALL"), whereis_addr(Prog, Addr)]);
%%format_j1c_op(_Prog, <<?J1INSTR_JUMP:?J1INSTR_WIDTH,
%%                Addr:?J1OP_INDEX_WIDTH/signed>>) ->
%%    io_lib:format("~s ~4.16.0B~n", [color:green("JMP"), Addr]);
%%format_j1c_op(_Prog, <<?J1INSTR_JUMP_COND:?J1INSTR_WIDTH,
%%                Addr:?J1OP_INDEX_WIDTH/signed>>) ->
%%    io_lib:format("~s ~4.16.0B~n", [color:green("JZ"), Addr]);
%%format_j1c_op(_Prog, <<?J1INSTR_ALU:3, RPC:1, Op:4, TN:1, TR:1, NTI:1,
%%                _Unused:1, Ds:2, Rs:2>>) ->
%%    format_j1c_alu(RPC, Op, TN, TR, NTI, Ds, Rs);
%%format_j1c_op(_Prog, <<Cmd:?J1BITS>>) ->
%%    io_lib:format("?UNKNOWN ~4.16.0B~n", [Cmd]).
%%
%%format_j1c_alu(RPC, Op, TN, TR, NTI, Ds, Rs) ->
%%    FormatOffset =
%%        fun(_, 0) -> [];
%%            (Prefix, 1) -> Prefix ++ "++";
%%            (Prefix, 2) -> Prefix ++ "--"
%%            end,
%%    [
%%        io_lib:format("~s", [color:red("ALU." ++ j1_op(Op))]),
%%        case RPC of 0 -> []; _ -> " RET" end,
%%        case TN of 0 -> []; _ -> " T->N" end,
%%        case TR of 0 -> []; _ -> " T->R" end,
%%        case NTI of 0 -> []; _ -> " [T]" end,
%%        FormatOffset(" DS", Ds),
%%        FormatOffset(" RS", Rs),
%%        "\n"
%%    ].
%%
%%j1_op(?J1OP_T)                  -> "T";
%%j1_op(?J1OP_N)                  -> "N";
%%j1_op(?J1OP_T_PLUS_N)           -> "T+N";
%%j1_op(?J1OP_T_AND_N)            -> "T&N";
%%j1_op(?J1OP_T_OR_N)             -> "T|N";
%%j1_op(?J1OP_T_XOR_N)            -> "T^N";
%%j1_op(?J1OP_INVERT_T)           -> "~T";
%%j1_op(?J1OP_N_EQ_T)             -> "N==T";
%%j1_op(?J1OP_N_LESS_T)           -> "N<T";
%%j1_op(?J1OP_N_RSHIFT_T)         -> "N>>T";
%%j1_op(?J1OP_T_MINUS_1)          -> "T-1";
%%j1_op(?J1OP_R)                  -> "R";
%%j1_op(?J1OP_INDEX_T)            -> "[T]";
%%j1_op(?J1OP_N_LSHIFT_T)         -> "N<<T";
%%j1_op(?J1OP_DEPTH)              -> "DEPTH";
%%j1_op(?J1OP_N_UNSIGNED_LESS_T)  -> "UN<T".

%%whereis_addr(#j1prog{dict=Words}, Addr) when Addr >= 0 ->
%%    case lists:keyfind(Addr, 2, Words) of
%%        {Name, _} -> io_lib:format("'~s'", [Name]);
%%        false -> "?"
%%    end;
%%whereis_addr(#j1prog{dict_nif=Nifs}, Addr) when Addr < 0 ->
%%    case lists:keyfind(Addr, 2, Nifs) of
%%        {Name, _} -> io_lib:format("~s '~s'", [color:blackb("NIF"), Name]);
%%        false -> "?"
%%    end.
