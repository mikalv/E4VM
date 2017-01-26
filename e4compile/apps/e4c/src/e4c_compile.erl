-module(e4c_compile).
-export([process/1]).

-include_lib("e4c/include/forth.hrl").

%% @doc Takes filename as input, produces compiled BEAM AST and processes it
process(F) ->
    case compile:file(F, [to_kernel, binary, report]) of
        {ok, M, Kernel} ->
            IR1 = e4c:try_do("Pass1 - Kernel Erlang to IC",
                             fun() -> e4_pass_kern:process(Kernel) end),
            IR2 = e4c:try_do("Pass2 - Mark variable scopes",
                             fun() -> e4_pass_scopes:process(IR1) end),
            FlatForth = e4c:try_do("Pass3 - Convert IC to Forth",
                                   fun() -> e4_pass_flatten:process(IR2) end),
            FlatForth2 = e4c:try_do("Pass4 - Optimize",
                                    fun() ->
                                        e4_pass_opt1:process(FlatForth) end),
            J1IC = e4c:try_do("Pass5 - Compile to J1 opcodes",
                          fun() -> j1c_pass_forth:compile(M, FlatForth2) end),
            J1Bin = e4c:try_do("Pass6 - Compile J1 IC to binary",
                               fun() -> j1c_pass_bin:compile(M, J1IC) end),
            e4c:try_do("Save binary output",
                       fun() ->
                           IOList = j1c_file:to_iolist(J1Bin),
                           file:write_file(j1c_file:bin_filename(F),
                                           iolist_to_binary(IOList))
                       end);
        E ->
            io:format("~n~s: ~p~n", [F, E])
    end.
