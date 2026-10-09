program bowtie_corvus_json_schema;

{$MODE DELPHI}
{$H+}
{$R+}

{ A Bowtie (https://github.com/bowtie-json-schema/bowtie) harness for corvus-json-schema, the Object Pascal JSON
  Schema evaluator of Corvus.JsonSchema.

  It speaks IHOP (one JSON request per line on standard input, one response per line on standard output).

  - start reports the implementation and its dialects.
  - dialect sets the dialect for schemas without $schema.
  - run compiles the case's schema with the case's registry as the document resolver and validates each instance.
    For annotations output it evaluates through a verbose results collector and reports each annotation with its
    instance location and its #... keyword location.
  - stop exits.

  A request is parsed with the library's own JSON parser. The schema, the registry's documents and the instances
  are handed to the library as values of that parsed request, so their text (the numbers included) is never written
  out again. A schema that cannot be compiled is an error for the case, and an instance that cannot be evaluated is
  an error for that instance. }

uses
  SysUtils,
  Corvus.JsonSchema,
  Corvus.JsonSchema.Document,
  Corvus.JsonSchema.Results;

const
  DialectCount = 5;
  DialectUris: array[0..DialectCount - 1] of UTF8String = (
    'https://json-schema.org/draft/2020-12/schema',
    'https://json-schema.org/draft/2019-09/schema',
    'http://json-schema.org/draft-07/schema#',
    'http://json-schema.org/draft-06/schema#',
    'http://json-schema.org/draft-04/schema#');
  Dialects: array[0..DialectCount - 1] of TJsonSchemaDialect = (
    Draft202012, Draft201909, Draft7, Draft6, Draft4);

  ReadChunk = 65536;

type
  { The registry of a case: an object of the request, whose property names are URIs and whose values are schema
    documents. Node is -1 when the case has none. }
  TRegistry = record
    Request: TJsonDocument;
    Node: NativeInt;
  end;
  PRegistry = ^TRegistry;

var
  { Standard input, read in chunks. The bytes InBuf[InStart .. InEnd-1] have been read and not yet returned. }
  InBuf: TBytes;
  InStart, InEnd: NativeInt;
  InDone: Boolean;

  { The response being written. }
  OutBuf: TBytes;
  OutLen: NativeInt;

  Started: Boolean;
  Dialect: TJsonSchemaDialect;

procedure Fail(const Message: RawByteString);
begin
  WriteLn(StdErr, Message);
  Halt(1);
end;

{ ------------------------------------------------------------------------------------------------------------------
  Input }

{ ReadLine is the next line of standard input, without its line feed. False at the end of the input. }
function ReadLine(out Line: TBytes): Boolean;
var
  Scan, Got: NativeInt;
begin
  Line := nil;
  Scan := InStart;
  while True do begin
    while (Scan < InEnd) and (InBuf[Scan] <> 10) do
      Inc(Scan);
    if Scan < InEnd then begin
      Line := Copy(InBuf, InStart, Scan - InStart);
      InStart := Scan + 1;
      Exit(True);
    end;
    if InDone then begin
      { The last line has no line feed. }
      Result := InEnd > InStart;
      if Result then
        Line := Copy(InBuf, InStart, InEnd - InStart);
      InStart := InEnd;
      Exit;
    end;
    if InStart > 0 then begin
      if InEnd > InStart then
        Move(InBuf[InStart], InBuf[0], InEnd - InStart);
      Dec(Scan, InStart);
      Dec(InEnd, InStart);
      InStart := 0;
    end;
    if Length(InBuf) - InEnd < ReadChunk then
      SetLength(InBuf, Length(InBuf) * 2 + ReadChunk);
    Got := FileRead(StdInputHandle, InBuf[InEnd], ReadChunk);
    if Got < 0 then
      Fail('cannot read standard input');
    if Got = 0 then
      InDone := True
    else
      Inc(InEnd, Got);
  end;
end;

function IsBlank(const Line: TBytes): Boolean;
var
  I: NativeInt;
begin
  for I := 0 to Length(Line) - 1 do
    if not (Line[I] in [9, 10, 13, 32]) then
      Exit(False);
  Result := True;
end;

{ ------------------------------------------------------------------------------------------------------------------
  Output }

procedure PutBytes(P: PByte; Count: NativeInt);
begin
  if Count <= 0 then
    Exit;
  if OutLen + Count > Length(OutBuf) then
    SetLength(OutBuf, (OutLen + Count) * 2);
  Move(P^, OutBuf[OutLen], Count);
  Inc(OutLen, Count);
end;

{ Put writes text as it is. A RawByteString parameter takes a string of any code page without converting it. }
procedure Put(const S: RawByteString);
begin
  if S <> '' then
    PutBytes(PByte(Pointer(S)), Length(S));
end;

procedure PutByte(B: Byte);
begin
  PutBytes(@B, 1);
end;

{ IsUtf8 says whether the bytes of S are well-formed UTF-8 (no overlong forms, no surrogates, nothing above
  U+10FFFF). }
function IsUtf8(const S: RawByteString): Boolean;
var
  I, N, More: NativeInt;
  B, Low, High: Byte;
begin
  N := Length(S);
  I := 1;
  while I <= N do begin
    B := Byte(S[I]);
    Inc(I);
    if B < $80 then
      Continue;
    Low := $80;
    High := $BF;
    case B of
      $C2..$DF: More := 1;
      $E0: begin More := 2; Low := $A0; end;
      $E1..$EC, $EE..$EF: More := 2;
      $ED: begin More := 2; High := $9F; end;
      $F0: begin More := 3; Low := $90; end;
      $F1..$F3: More := 3;
      $F4: begin More := 3; High := $8F; end;
    else
      Exit(False);
    end;
    while More > 0 do begin
      if (I > N) or (Byte(S[I]) < Low) or (Byte(S[I]) > High) then
        Exit(False);
      Low := $80;
      High := $BF;
      Inc(I);
      Dec(More);
    end;
  end;
  Result := True;
end;

{ PutString writes text as a JSON string. Quotation marks, backslashes and control characters are escaped, and
  everything else is written as the UTF-8 it is. Text that is not UTF-8 (which no message of the library is) has
  each byte outside ASCII replaced by U+FFFD, so that the response is always JSON. }
procedure PutString(const S: RawByteString);
const
  Hex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  I, RunStart: NativeInt;
  B: Byte;
  Valid: Boolean;
begin
  Valid := IsUtf8(S);
  PutByte(Ord('"'));
  RunStart := 1;
  for I := 1 to Length(S) do begin
    B := Byte(S[I]);
    if (B >= $20) and (B <> Ord('"')) and (B <> Ord('\')) and (Valid or (B < $80)) then
      Continue;
    PutBytes(PByte(Pointer(S)) + (RunStart - 1), I - RunStart);
    RunStart := I + 1;
    case B of
      Ord('"'): Put('\"');
      Ord('\'): Put('\\');
      8: Put('\b');
      9: Put('\t');
      10: Put('\n');
      12: Put('\f');
      13: Put('\r');
    else
      if B < $20 then begin
        Put('\u00');
        PutByte(Ord(Hex[B shr 4]));
        PutByte(Ord(Hex[B and 15]));
      end else
        Put('�');
    end;
  end;
  PutBytes(PByte(Pointer(S)) + (RunStart - 1), Length(S) + 1 - RunStart);
  PutByte(Ord('"'));
end;

{ Send writes the response, as one line, to standard output. }
procedure Send;
var
  Done, Wrote: NativeInt;
begin
  PutByte(10);
  Done := 0;
  while Done < OutLen do begin
    Wrote := FileWrite(StdOutputHandle, OutBuf[Done], OutLen - Done);
    if Wrote <= 0 then
      Halt(1);
    Inc(Done, Wrote);
  end;
  OutLen := 0;
end;

{ ------------------------------------------------------------------------------------------------------------------
  The request }

{ Value is the value N of D as a document: it shares the arrays of D, so nothing is copied and nothing is written
  out again. }
function Value(const D: TJsonDocument; N: NativeInt): TJsonDocument;
begin
  Result := D;
  Result.Root := Int32(N);
end;

{ Member is the value of an object's property, or -1 when N is not an object or has no such property. }
function Member(const D: TJsonDocument; N: NativeInt; const Name: UTF8String): NativeInt;
begin
  if (N < 0) or (DocKind(D, N) <> KindObject) then
    Exit(-1);
  Result := DocProperty(D, N, Name);
end;

{ StringMember is the value of an object's string property, or '' when it has none. }
function StringMember(const D: TJsonDocument; N: NativeInt; const Name: UTF8String): UTF8String;
var
  M: NativeInt;
begin
  M := Member(D, N, Name);
  if (M < 0) or (DocKind(D, M) <> KindString) then
    Exit('');
  Result := DocStrCopy(D, Int32(M));
end;

function StripFragment(const Uri: UTF8String): UTF8String;
var
  Hash: NativeInt;
begin
  Hash := Pos('#', Uri);
  if Hash = 0 then
    Result := Uri
  else
    Result := Copy(Uri, 1, Hash - 1);
end;

{ ResolveFromRegistry is the document resolver of a compilation: the registry's document for a URI, with fragments
  disregarded on both sides. Context is the case's TRegistry. }
function ResolveFromRegistry(Context: Pointer; const Uri: UTF8String; out Doc: TJsonDocument): Boolean;
var
  Registry: PRegistry;
  Wanted: UTF8String;
  Key, I: NativeInt;
begin
  Result := False;
  Doc := Default(TJsonDocument);
  Registry := PRegistry(Context);
  if Registry^.Node < 0 then
    Exit;
  try
    Wanted := StripFragment(Uri);
    { An object's children are its names and values in turn. }
    Key := DocFirst(Registry^.Request, Registry^.Node);
    for I := 1 to DocCount(Registry^.Request, Registry^.Node) do begin
      if StripFragment(DocStrCopy(Registry^.Request, Int32(Key))) = Wanted then begin
        Doc := Value(Registry^.Request, Key + 1);
        Result := True;
      end;
      Inc(Key, 2);
    end;
  except
    Result := False;
  end;
end;

{ ErrorText is what an exception says. }
function ErrorText(E: Exception): RawByteString;
begin
  if E is EJsonSchemaError then
    Result := EJsonSchemaError(E).Utf8Message
  else
    Result := RawByteString(E.ClassName) + ': ' + RawByteString(E.Message);
end;

procedure PutErrored(const Message: RawByteString);
begin
  Put('"errored":true,"context":{"message":');
  PutString(Message);
  Put('}');
end;

{ UnescapeToken is a JSON pointer token as the text it stands for. }
function UnescapeToken(const Token: UTF8String): UTF8String;
begin
  Result := StringReplace(StringReplace(Token, '~1', '/', [rfReplaceAll]), '~0', '~', [rfReplaceAll]);
end;

{ ------------------------------------------------------------------------------------------------------------------
  The commands }

function OsRelease: RawByteString;
var
  Handle: THandle;
  Buffer: array[0..255] of Byte;
  Got: NativeInt;
begin
  Result := '';
  { The kernel's release on Linux, which is where Bowtie runs harnesses. }
  Handle := FileOpen('/proc/sys/kernel/osrelease', fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  Got := FileRead(Handle, Buffer, SizeOf(Buffer));
  FileClose(Handle);
  while (Got > 0) and (Buffer[Got - 1] <= 32) do
    Dec(Got);
  if Got > 0 then
    SetString(Result, PAnsiChar(@Buffer[0]), Got);
end;

procedure Start(const D: TJsonDocument);
var
  Version: NativeInt;
  I: Int32;
begin
  Version := Member(D, D.Root, 'version');
  if (Version < 0) or (DocKind(D, Version) <> KindNumber) or (JsonText(Value(D, Version)) <> '1') then
    Fail('unsupported IHOP version');
  Started := True;
  Put('{"version":1,"implementation":{"language":"pascal","name":"corvus-json-schema","version":');
  PutString(JsonSchemaVersion);
  Put(',"homepage":"https://github.com/corvus-dotnet/Corvus.JsonSchema"');
  Put(',"documentation":"https://github.com/corvus-dotnet/Corvus.JsonSchema/tree/main/src-pas/corvus-json-schema"');
  Put(',"issues":"https://github.com/corvus-dotnet/Corvus.JsonSchema/issues"');
  Put(',"source":"https://github.com/corvus-dotnet/Corvus.JsonSchema"');
  Put(',"dialects":[');
  for I := 0 to DialectCount - 1 do begin
    if I > 0 then
      Put(',');
    PutString(DialectUris[I]);
  end;
  Put('],"os":');
  PutString(LowerCase({$I %FPCTARGETOS%}));
  Put(',"os_version":');
  PutString(OsRelease);
  Put(',"language_version":');
  { The version of Free Pascal that compiled the harness and the library. }
  PutString({$I %FPCVERSION%});
  Put('}}');
  Send;
end;

procedure SetDialect(const D: TJsonDocument);
var
  Uri: UTF8String;
  I: Int32;
begin
  Uri := StringMember(D, D.Root, 'dialect');
  for I := 0 to DialectCount - 1 do
    if DialectUris[I] = Uri then begin
      Dialect := Dialects[I];
      Put('{"ok":true}');
      Send;
      Exit;
    end;
  Put('{"ok":false}');
  Send;
end;

{ PutResult evaluates one instance and writes its result. }
procedure PutResult(const Validator: IJsonSchemaValidator; const Instance: TJsonDocument; Annotations: Boolean);
var
  Valid: Boolean;
  Error: UTF8String;
  Results: TJsonSchemaResults;
  Found: TJsonSchemaAnnotationArray;
  I: Int32;
begin
  if not Annotations then begin
    Valid := Validator.TryIsValid(Instance, Error);
    if Error <> '' then begin
      PutErrored(Error);
      Exit;
    end;
    if Valid then
      Put('"valid":true')
    else
      Put('"valid":false');
    Exit;
  end;

  Results := NewJsonSchemaResults(Verbose);
  Valid := Validator.TryEvaluate(Instance, Results, Error);
  if Error <> '' then begin
    PutErrored(Error);
    Exit;
  end;
  if Valid then
    Put('"valid":true,"annotations":[')
  else
    Put('"valid":false,"annotations":[');
  { The keyword of an annotation is a JSON pointer token. Bowtie has the keyword itself, and the keyword's location
    as the fragment of the schema location followed by the token. }
  Found := ResultAnnotations(Results);
  for I := 0 to Length(Found) - 1 do begin
    if I > 0 then
      Put(',');
    Put('{"keyword":');
    PutString(UnescapeToken(Found[I].Keyword));
    Put(',"instanceLocation":');
    PutString(Found[I].InstanceLocation);
    Put(',"keywordLocation":');
    PutString(SchemaLocationFragment(Found[I].SchemaLocation + '/' + Found[I].Keyword));
    { The value is JSON text already. }
    Put(',"annotation":');
    Put(Found[I].Value);
    Put('}');
  end;
  Put(']');
end;

procedure Run(const D: TJsonDocument);
var
  Seq, TestCase, Schema, Tests, Test, Instance, Mark: NativeInt;
  Registry: TRegistry;
  Options: TJsonSchemaOptions;
  Validator: IJsonSchemaValidator;
  Annotations: Boolean;
  I: Int32;
begin
  Put('{"seq":');
  Seq := Member(D, D.Root, 'seq');
  if Seq < 0 then
    Put('null')
  else
    Put(JsonText(Value(D, Seq)));
  Put(',');

  TestCase := Member(D, D.Root, 'case');
  Schema := Member(D, TestCase, 'schema');
  Tests := Member(D, TestCase, 'tests');
  if (Schema < 0) or (Tests < 0) or (DocKind(D, Tests) <> KindArray) then
    Fail('a run request needs a case with a schema and tests');

  Registry.Request := D;
  Registry.Node := Member(D, TestCase, 'registry');
  if (Registry.Node >= 0) and (DocKind(D, Registry.Node) <> KindObject) then
    Registry.Node := -1;

  { Every failure to compile is reported for the case. }
  try
    Options := DefaultJsonSchemaOptions;
    WithDefaultDialect(Options, Dialect);
    WithDocumentResolver(Options, ResolveFromRegistry, @Registry);
    Validator := CompileJsonSchema(Value(D, Schema), Options);
  except
    on E: Exception do begin
      PutErrored(ErrorText(E));
      Put('}');
      Send;
      Exit;
    end;
  end;

  Annotations := StringMember(D, D.Root, 'output') = 'annotations';
  Put('"results":[');
  { An array's children are its items. }
  Test := DocFirst(D, Tests);
  for I := 0 to DocCount(D, Tests) - 1 do begin
    if I > 0 then
      Put(',');
    Put('{');
    { An error for one instance does not stop the others. What was written of its result is taken back. }
    Mark := OutLen;
    try
      Instance := Member(D, Test + I, 'instance');
      if Instance < 0 then
        PutErrored('the test has no instance')
      else
        PutResult(Validator, Value(D, Instance), Annotations);
    except
      on E: Exception do begin
        OutLen := Mark;
        PutErrored(ErrorText(E));
      end;
    end;
    Put('}');
  end;
  Put(']}');
  Send;
end;

var
  Line: TBytes;
  Request: TJsonDocument;
  Error, Command: UTF8String;
  ErrorOffset: Int32;
begin
  Started := False;
  Dialect := Draft202012;
  Line := nil;
  while ReadLine(Line) do begin
    if IsBlank(Line) then
      Continue;
    if not TryParseJson(Line, Request, Error, ErrorOffset) then
      Fail('the request is not JSON: ' + Error);
    Command := StringMember(Request, Request.Root, 'cmd');
    if (Command <> 'start') and not Started then
      Fail('not started');
    if Command = 'start' then
      Start(Request)
    else if Command = 'dialect' then
      SetDialect(Request)
    else if Command = 'run' then
      Run(Request)
    else if Command = 'stop' then
      Halt(0)
    else
      Fail('unknown command "' + Command + '"');
  end;
end.
