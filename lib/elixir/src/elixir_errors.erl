%% A bunch of helpers to help to deal with errors in Elixir source code.
%% This is not exposed in the Elixir language.
%%
%% Notice this is also called by the Erlang backend, so we also support
%% the line number to be none (as it may happen in some erlang errors).
-module(elixir_errors).
-export([compile_error/3, compile_error/4,
         form_error/4, form_warn/4, parse_error/4, warn/1, warn/3]).
-include("elixir.hrl").

-spec warn(non_neg_integer() | none, unicode:chardata(), unicode:chardata()) -> ok.
warn(none, File, Warning) ->
  warn(0, File, Warning);
warn(Line, File, Warning) when is_integer(Line), is_binary(File) ->
  CompilerPid = get(elixir_compiler_pid),
  if
    CompilerPid =/= undefined ->
      CompilerPid ! {warning, File, Line, Warning};
    true -> ok
  end,
  warn([Warning, "\n  ", file_format(Line, File), $\n]).

-spec warn(unicode:chardata()) -> ok.
warn(Message) ->
  CompilerPid = get(elixir_compiler_pid),
  if
    CompilerPid =/= undefined ->
      elixir_code_server:cast({register_warning, CompilerPid});
    true -> ok
  end,
  io:put_chars(standard_error, [warning_prefix(), Message, $\n]),
  ok.

warning_prefix() ->
  case application:get_env(elixir, ansi_enabled) of
    {ok, true} -> <<"\e[33mwarning: \e[0m">>;
    _ -> <<"warning: ">>
  end.

%% General forms handling.

-spec form_error(list(), binary(), module(), any()) -> no_return().
form_error(Meta, File, Module, Desc) ->
  compile_error(Meta, File, Module:format_error(Desc)).

-spec form_warn(list(), binary(), module(), any()) -> ok.
form_warn(Meta, File, Module, Desc) when is_list(Meta) ->
  {MetaFile, MetaLine} = meta_location(Meta, File),
  warn(MetaLine, MetaFile, Module:format_error(Desc)).

%% Compilation error.

-spec compile_error(list(), binary(), binary() | unicode:charlist()) -> no_return().
-spec compile_error(list(), binary(), string(), list()) -> no_return().

compile_error(Meta, File, Message) when is_binary(Message) ->
  {MetaFile, MetaLine} = meta_location(Meta, File),
  raise(MetaLine, MetaFile, 'Elixir.CompileError', Message);
compile_error(Meta, File, Message) when is_list(Message) ->
  {MetaFile, MetaLine} = meta_location(Meta, File),
  raise(MetaLine, MetaFile, 'Elixir.CompileError',
        elixir_utils:characters_to_binary(Message)).

compile_error(Meta, File, Format, Args) when is_list(Format)  ->
  compile_error(Meta, File, io_lib:format(Format, Args)).

%% Tokenization parsing/errors.

-spec parse_error(non_neg_integer(), binary() | {binary(), binary()},
                  binary(), binary()) -> no_return().
parse_error(Line, File, Error, <<>>) ->
  Message = case Error of
    <<"syntax error before: ">> -> <<"syntax error: expression is incomplete">>;
    _ -> Error
  end,
  raise(Line, File, 'Elixir.TokenMissingError', Message);

%% Show a nicer message for end of line
parse_error(Line, File, <<"syntax error before: ">>, <<"eol">>) ->
  raise(Line, File, 'Elixir.SyntaxError',
        <<"unexpectedly reached end of line. The current expression is invalid or incomplete">>);

%% Show a nicer message for missing end tokens
parse_error(Line, File, <<"syntax error before: ">>, <<"'end'">>) ->
  raise(Line, File, 'Elixir.SyntaxError', <<"unexpected token: end">>);

%% TODO: Remove workarounds for sigils, aliases, binaries and interpolation.

%% Produce a human-readable message for errors before a sigil
parse_error(Line, File, <<"syntax error before: ">>, <<"{sigil,", _Rest/binary>> = Full) ->
  {sigil, _, Sigil, [Content | _], _, _} = parse_erl_term(Full),
  Content2 = case is_binary(Content) of
    true -> Content;
    false -> <<>>
  end,
  Message = <<"syntax error before: sigil \~", Sigil, " starting with content '", Content2/binary, "'">>,
  raise(Line, File, 'Elixir.SyntaxError', Message);

%% Aliases are wrapped in ['']
parse_error(Line, File, Error, <<"['", _/binary>> = Full) when is_binary(Error) ->
  [AliasAtom] = parse_erl_term(Full),
  Alias = atom_to_binary(AliasAtom, utf8),
  raise(Line, File, 'Elixir.SyntaxError', <<Error/binary, Alias/binary>>);

%% Binaries (and interpolation) are wrapped in [<<...>>]
parse_error(Line, File, Error, <<"[", _/binary>> = Full) when is_binary(Error) ->
  Term = case parse_erl_term(Full) of
    [H | _] when is_binary(H) -> <<$", H/binary, $">>;
    _ -> <<$">>
  end,
  raise(Line, File, 'Elixir.SyntaxError', <<Error/binary, Term/binary>>);

%% Given a string prefix and suffix to insert the token inside the error message rather than append it
parse_error(Line, File, {ErrorPrefix, ErrorSuffix}, Token) when is_binary(ErrorPrefix), is_binary(ErrorSuffix), is_binary(Token) ->
  Message = <<ErrorPrefix/binary, Token/binary, ErrorSuffix/binary >>,
  raise(Line, File, 'Elixir.SyntaxError', Message);

%% Everything else is fine as is
parse_error(Line, File, Error, Token) when is_binary(Error), is_binary(Token) ->
  Message = <<Error/binary, Token/binary >>,
  raise(Line, File, 'Elixir.SyntaxError', Message).

%% Helper to parse terms which have been converted to binaries
parse_erl_term(Term) ->
  {ok, Tokens, _} = erl_scan:string(binary_to_list(Term)),
  {ok, Parsed} = erl_parse:parse_term(Tokens ++ [{dot, 1}]),
  Parsed.

%% Helpers

file_format(0, File) ->
  io_lib:format("~ts", [elixir_utils:relative_to_cwd(File)]);

file_format(Line, File) ->
  io_lib:format("~ts:~w", [elixir_utils:relative_to_cwd(File), Line]).

meta_location(Meta, File) ->
  case elixir_utils:meta_location(Meta) of
    {F, L} -> {F, L};
    nil    -> {File, ?line(Meta)}
  end.

raise(none, File, Kind, Message) ->
  raise(0, File, Kind, Message);
raise({Line, _, _}, File, Kind, Message) when is_integer(Line) ->
  raise(Line, File, Kind, Message);
raise(Line, File, Kind, Message) when is_integer(Line), is_binary(File), is_binary(Message) ->
  Stacktrace = try throw(ok) catch ok -> erlang:get_stacktrace() end,
  Exception = Kind:exception([{description, Message}, {file, File}, {line, Line}]),
  erlang:raise(error, Exception, tl(Stacktrace)).
