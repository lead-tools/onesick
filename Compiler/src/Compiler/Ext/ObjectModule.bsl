
// Транслятор

// Результат трансляции.
Var Result; // array

// Относительные адреса переменных и параметров.
// Абсолютные адреса методов хранятся тоже тут (:
Var OffsetMap; // map[Decl](number)

// Количество вызовов функций в последних разобранных выражениях.
// Нужно для вычисления адреса результата функции и для уборки мусора.
Var CallsCount; // number

// Суммарное количество параметров и переменных в методе.
Var ItemsCount; // map[Sign](number)

// Текущий метод (или модуль, при генерации тела модуля)
Var CurrentCaller; // Sign, Module

// Точки вызова метода.
// Нужны для отложенной генерации вызовов, так как порядок
// объявления методов произвольный и не все адреса известны сразу.
Var CallSites; // map[Sign](array)

// Признак что последней инструкцией был Возврат.
Var LastIsReturn; // boolean

// Вложенные области видимости для циклов.
// Нужны для определения адресов переходов в инструкциях Прервать и Продолжить.
Var LoopScope; // structure

// Списки для отложенной генерации переходов по меткам.
// Будет переделано, т.к. нужны области видимости для контроля семантики.
Var Labels;   // map[string](number)
Var GotoList; // map[string]array(number)

// Перечисления
Var Nodes;         // enum
Var Tokens;        // enum
Var Directives;    // enum
Var Operators;     // structure as map[one of Tokens](string)

Procedure Init(BSLParser) Export	
	Operators = New Structure(
		"Eql, Neq, Lss, Gtr, Leq, Geq, Add, Sub, Mul, Div, Mod, Or, And, Not",
		"=", "<>", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", " Or ", " And ", "Not "
	);
	Nodes = BSLParser.Nodes();
	Tokens = BSLParser.Tokens();
	Directives = BSLParser.Directives();
	Result = New Array;
	OffsetMap = New Map;
	CallsCount = 0;
	ItemsCount = New Map;
	CallSites = New Map;
	Labels = New Map;
	GotoList = New Map;
	LastIsReturn = False;
EndProcedure // Init()

Function Hooks() Export
	Var Hooks;
	Hooks = New Array;
	Hooks.Add("VisitModule");
	Return Hooks;
EndFunction // Hooks()

Function Result() Export
	Return Result;
EndFunction // Refult()

Procedure OpenLoopScope()
	LoopScope = New Structure("Outer, Break, Continue", LoopScope, New Array, New Array);
EndProcedure // OpenLoopScope()

Procedure CloseLoopScope()
	LoopScope = LoopScope.Outer;
EndProcedure // CloseLoopScope()

Procedure VisitModule(Module, M = Undefined, Counters = Undefined) Export
	
	Address = 0; // По нулевому адресу размещается отладочная информация.
	
	Result.Add(); // Переход к телу модуля (заполняется отложенно).
	
	// Первый проход: назначение адресов переменным и параметрам.
	
	For Each Decl In Module.Decls Do
		
		Type = Decl.Type;
		
		If Type = Nodes.VarModListDecl Then		
			
			// Переменные модуля имеют абсолютную адресацию.
			
			For Each VarDecl In Decl.List Do
				If VarDecl.Directive = Directives.AtClient Then
					Address = Address + 1;
					OffsetMap[VarDecl] = Address;
				EndIf; 
			EndDo;
			
		ElsIf Type = Nodes.MethodDecl Then 
			
			Sign = Decl.Sign;
			
			// Параметры и локальные переменные адресуются относительно кадра процедуры (Address = FP + ItemOffset).
			
			ItemOffset = 0;
			
			For Each ItemDecl In Sign.Params Do
				ItemOffset = ItemOffset + 1;
				OffsetMap[ItemDecl] = ItemOffset;
			EndDo;
			
			For Each ItemDecl In Decl.Vars Do
				ItemOffset = ItemOffset + 1;
				OffsetMap[ItemDecl] = ItemOffset;
			EndDo;
			
			For Each ItemDecl In Decl.Auto Do
				ItemOffset = ItemOffset + 1;
				OffsetMap[ItemDecl] = ItemOffset;
			EndDo;		
			
			ItemsCount[Sign] = ItemOffset;
			
		Else
			// error
		EndIf;
		
	EndDo;
	
	// Второй проход: генерация кода методов.
	
	For Each Decl In Module.Decls Do
		
		If Decl.Type = Nodes.MethodDecl Then 
			
			Sign = Decl.Sign;
			OffsetMap[Sign] = Result.Count();
			CurrentCaller = Sign;
			Result.Add(StrTemplate("// Method %1()", Sign.Name));
			
			VisitStatements(Decl.Body);
			
			If Not LastIsReturn Then // если последней инструкцией был возврат, то эпилог уже сгенерирован
				EmitEpilog();
			EndIf; 
			
		EndIf;
		
	EndDo;
	
	// Генерация кода тела модуля.
	
	Result.Add("// Module body");
	
	// Локальные переменные модуля имеют относительную адресацию.
	ItemOffset = 0;
	For Each ItemDecl In Module.Auto Do
		ItemOffset = ItemOffset + 1;
		OffsetMap[ItemDecl] = ItemOffset;
	EndDo;	
	ItemsCount[Module] = ItemOffset;
	
	// Установка указателя кадра тела модуля, установка указателя вершины стека и переход к телу модуля
	Result[0] = StrTemplate("FP=%1;SP=%2;IP=%3;", Fmt(Address), Fmt(Address + ItemOffset), Fmt(Result.UBound()));
	
	CurrentCaller = Module;
	
	VisitStatements(Module.Body);
	
	If ItemOffset > 0 Then
		// Нужно почистить локальные переменные, чтобы избежать утечки памяти.
		Result.Add(StrTemplate("For _=SP-%1 To SP Do M[_]=Undefined EndDo;SP=SP-%2; // GC vars", ItemOffset-1, ItemOffset));
	EndIf; 
	
	// Установка вызовов методов. Выполняется отложенно,
	// так как на этапе генерации адрес вызываемого метода может быть не известен.
	For Each CallSite In CallSites Do
		For Each Index In CallSite.Value Do
			Result[Index] = StrTemplate("IP=%1; // Call %2()", Fmt(OffsetMap[CallSite.Key]), CallSite.Key.Name);
		EndDo; 
	EndDo; 
	
EndProcedure // VisitModule()

Procedure VisitStatements(Statements)
	For Each Stmt In Statements Do
		VisitStmt(Stmt);
	EndDo;
	For Each Item In GotoList Do
		For Each Addr In Item.Value Do
			Result[Addr] = StrTemplate("IP=%1; // goto", Fmt(Labels[Item.Key]));
		EndDo; 
	EndDo; 
EndProcedure // VisitStatements()

Procedure GarbageCollectionAfterCalls(Buffer)
	// После вызовов функций нужно чистить результаты, чтобы избежать утечки памяти.
	If CallsCount > 0 Then
		Buffer.Add(StrTemplate("For _=SP-%1 To SP Do M[_]=Undefined EndDo;SP=SP-%2; // GC after function calls", CallsCount-1, CallsCount));
		CallsCount = 0;
	EndIf;
EndProcedure 

Procedure EmitEpilog()
	// Эпилог вызова метода. Чистка мусора и восстановление регистров.
	Result.Add("For _=FP+1 To SP Do M[_]=Undefined EndDo;SP=FP-1;FP=M[FP];IP=M[SP];SP=SP-1; // GC, Restore FP, Return, del ret addr");
EndProcedure 

#Region VisitStmt

Procedure VisitStmt(Stmt)
	Type = Stmt.Type;	
	LastIsReturn = False;
	If Type = Nodes.AssignStmt Then
		VisitAssignStmt(Stmt);
	ElsIf Type = Nodes.ReturnStmt Then
		VisitReturnStmt(Stmt);
		LastIsReturn = True;
	ElsIf Type = Nodes.BreakStmt Then
		VisitBreakStmt(Stmt);
	ElsIf Type = Nodes.ContinueStmt Then
		VisitContinueStmt(Stmt);
	ElsIf Type = Nodes.RaiseStmt Then
		VisitRaiseStmt(Stmt);
	ElsIf Type = Nodes.ExecuteStmt Then
		VisitExecuteStmt(Stmt);
	ElsIf Type = Nodes.CallStmt Then
		VisitCallStmt(Stmt);
	ElsIf Type = Nodes.IfStmt Then
		VisitIfStmt(Stmt);
	ElsIf Type = Nodes.WhileStmt Then
		VisitWhileStmt(Stmt);
	ElsIf Type = Nodes.ForStmt Then
		VisitForStmt(Stmt);
	ElsIf Type = Nodes.ForEachStmt Then
		VisitForEachStmt(Stmt);
	ElsIf Type = Nodes.TryStmt Then
		VisitTryStmt(Stmt);
	ElsIf Type = Nodes.GotoStmt Then
		VisitGotoStmt(Stmt);
	ElsIf Type = Nodes.LabelStmt Then
		VisitLabelStmt(Stmt);
	Else
		// error
	EndIf;
EndProcedure // VisitStmt()

Procedure VisitAssignStmt(AssignStmt)
	Var Decl, Buffer, Left, Right;
	
	Decl = AssignStmt.Left.Head.Decl;
	
	Buffer = New Array; 
	VisitIdentExpr(AssignStmt.Left, Buffer);
	Left = StrConcat(Buffer);
	
	Buffer.Clear();
	CallsCount = 0;
	VisitExpr(AssignStmt.Right, Buffer);
	Right = StrConcat(Buffer);
	
	Result.Add(StrTemplate("%1=%2; // Assign", Left, Right));
	
	GarbageCollectionAfterCalls(Result); 
	
EndProcedure // VisitAssignStmt()

Procedure VisitCallStmt(CallStmt)
	Var Buffer;
	
	Buffer = New Array;
	CallsCount = 0;
	VisitIdentExpr(CallStmt.Ident, Buffer);
	If CallStmt.Ident.Head.Decl = Undefined
		Or CallStmt.Ident.Args = Undefined Then
		Buffer.Add(";");
		Result.Add(StrConcat(Buffer));
	EndIf;
	
	GarbageCollectionAfterCalls(Result);
	
EndProcedure // VisitCallStmt()

Procedure VisitReturnStmt(ReturnStmt)
	Var Buffer, Right;
	
	If ReturnStmt.Expr <> Undefined Then
		
		Buffer = New Array;
		CallsCount = 0;
		VisitExpr(ReturnStmt.Expr, Buffer);
		Right = StrConcat(Buffer);
		Result.Add(StrTemplate("M[FP-2]=%1; // Return", Right));
		
		GarbageCollectionAfterCalls(Result);
		
		EmitEpilog();
		
	EndIf;
	
EndProcedure // VisitReturnStmt()

Procedure VisitBreakStmt(BreakStmt)
	
	Result.Add(); // Переход на конец цикла (заполняется отложенно).
	LoopScope.Break.Add(Result.UBound());
	
EndProcedure // VisitBreakStmt()

Procedure VisitContinueStmt(ContinueStmt)
	
	Result.Add(); // Переход на начало цикла (заполняется отложенно).
	LoopScope.Continue.Add(Result.UBound());
	
EndProcedure // VisitContinueStmt()

Procedure VisitRaiseStmt(RaiseStmt)
	Var Buffer;
	
	If RaiseStmt.Expr <> Undefined Then
		Buffer = New Array;
		VisitExpr(RaiseStmt.Expr, Buffer);
		Result.Add(StrTemplate("Raise %1;", StrConcat(Buffer)));
	Else
		Result.Add("Raise;");
	EndIf;
	
EndProcedure // VisitRaiseStmt()

Procedure VisitExecuteStmt(ExecuteStmt)
	Var Buffer;
	
	Buffer = New Array;
	Buffer.Add("Execute ");
	VisitExpr(ExecuteStmt.Expr, Buffer);
	Buffer.Add(";");
	Result.Add(StrConcat(Buffer));
	
EndProcedure // VisitExecuteStmt()

Procedure VisitIfStmt(IfStmt)
	
	CallsCount = 0;
	
	Ends = New Array;
	List = New Array;
	
	Buffer = New Array;	
	VisitExpr(IfStmt.Cond, Buffer);
	Result.Add(StrConcat(Buffer)); // deferred	
	Item = New Structure("Addr, CallIndex, Goto", Result.UBound(), CallsCount);
	List.Add(Item);
	
	GarbageCollectionAfterCalls(Result);
	
	VisitStatements(IfStmt.Then);	
	Result.Add(); Ends.Add(Result.UBound()); // deferred
	
	ElsIfList = IfStmt.ElsIf;
	If ElsIfList <> Undefined Then
		For Index = 0 To ElsIfList.UBound() Do
			
			ElsIfStmt = ElsIfList[Index];		
			
			Item.Goto = Result.UBound();
			
			Buffer = New Array;
			VisitExpr(ElsIfStmt.Cond, Buffer);			
			Result.Add(StrConcat(Buffer)); // deferred
			Item = New Structure("Addr, CallIndex, Goto", Result.UBound(), CallsCount);
			List.Add(Item); 
			
			GarbageCollectionAfterCalls(Result);
			
			VisitStatements(ElsIfStmt.Then);
			Result.Add(); Ends.Add(Result.UBound()) // deferred
			
		EndDo; 
	EndIf;
	
	If IfStmt.Else <> Undefined Then
		Item.Goto = Result.UBound();
		VisitStatements(IfStmt.Else.Body);
	EndIf; 
	
	For Each Item In List Do
		If Item.Goto = Undefined Then
			Item.Goto = Fmt(Result.UBound());
		EndIf; 
		Buffer = New Array;
		Buffer.Add(StrTemplate("If Not (%1) Then IP=%2;", Result[Item.Addr], Fmt(Item.Goto)));
		If Item.CallIndex > 0 Then
			GarbageCollectionAfterCalls(Buffer);
		EndIf;
		Buffer.Add("EndIf;");
		Result[Item.Addr] = StrConcat(Buffer);
	EndDo; 
	
	GotoEnd = StrTemplate("IP=%1;", Fmt(Result.UBound()));
	For Each Index In Ends Do
		Result[Index] = GotoEnd;
	EndDo; 
	
EndProcedure // VisitIfStmt()

Procedure VisitWhileStmt(WhileStmt)
	
	OpenLoopScope();
	
	CallsCount = 0;
	
	HeadAddr = Result.UBound();
	
	Buffer = New Array;
	VisitExpr(WhileStmt.Cond, Buffer);
	Result.Add();
	ExprAddr = Result.UBound(); 
	
	GarbageCollectionAfterCalls(Result);
	
	VisitStatements(WhileStmt.Body);
	
	Result.Add(StrTemplate("IP=%1;", Fmt(HeadAddr)));
	Result[ExprAddr] = StrTemplate("If Not (%1) Then IP=%2 EndIf;", StrConcat(Buffer), Fmt(Result.UBound()));
	
	For Each Addr In LoopScope.Break Do
		Result[Addr] = StrTemplate("IP=%1;", Fmt(Result.UBound()));
	EndDo;
	LoopScope.Break.Clear();
	
	For Each Addr In LoopScope.Continue Do
		Result[Addr] = StrTemplate("IP=%1;", Fmt(HeadAddr));
	EndDo;
	LoopScope.Continue.Clear();
	
	CloseLoopScope();
	
EndProcedure // VisitWhileStmt()

Procedure VisitForStmt(ForStmt)
	
	OpenLoopScope();
	
	CallsCount = 0;
	
	Buffer = New Array;
	VisitIdentExpr(ForStmt.Ident, Buffer);
	Left = StrConcat(Buffer);
	
	Buffer = New Array;
	VisitExpr(ForStmt.From, Buffer);
	Right = StrConcat(Buffer);
	
	Result.Add(StrTemplate("%1=%2; // Init", Left, Right));
	HeadAddr = Result.UBound();
	
	Buffer = New Array;
	VisitExpr(ForStmt.To, Buffer);
	Result.Add();
	ExprAddr = Result.UBound();	
	
	GarbageCollectionAfterCalls(Result);
	
	VisitStatements(ForStmt.Body);
	
	Result.Add(StrTemplate("%1=%1+1;IP=%2;", Left, HeadAddr));
	Result[ExprAddr] = StrTemplate("If %1>%2 Then IP=%3 EndIf;", Left, StrConcat(Buffer), Fmt(Result.UBound()));
	
	For Each Addr In LoopScope.Break Do
		Result[Addr] = StrTemplate("IP=%1;", Fmt(Result.UBound()));
	EndDo;
	LoopScope.Break.Clear();
	
	For Each Addr In LoopScope.Continue Do
		Result[Addr] = StrTemplate("IP=%1;", Fmt(HeadAddr));
	EndDo;
	LoopScope.Continue.Clear();
	
	CloseLoopScope();
	
EndProcedure // VisitForStmt()

Procedure VisitForEachStmt(ForEachStmt)
	
	OpenLoopScope();
	
	CallsCount = 0;
	
	Buffer = New Array;
	VisitIdentExpr(ForEachStmt.Ident, Buffer);
	Left = StrConcat(Buffer);
	
	Buffer = New Array;
	VisitExpr(ForEachStmt.In, Buffer);
	Result.Add(StrTemplate("A=New Array;For Each X In %1 Do A.Add(X) EndDo;SP=SP+1;M[SP]=A;SP=SP+1;M[SP]=A.UBound();SP=SP+1;M[SP]=0;A=Undefined;X=Undefined;", StrConcat(Buffer)));	
	HeadAddr = Result.UBound();
	
	Result.Add();
	ExprAddr = Result.UBound();		
	
	GarbageCollectionAfterCalls(Result);
	
	VisitStatements(ForEachStmt.Body);
	
	Result.Add(StrTemplate("IP=%1;", HeadAddr));
	Result[ExprAddr] = StrTemplate("If M[SP]>M[SP-1] Then IP=%1 Else %2=M[SP-2][M[SP]]; M[SP]=M[SP]+1 EndIf;", Fmt(Result.UBound()), Left);
	
	For Each Addr In LoopScope.Break Do
		Result[Addr] = StrTemplate("IP=%1;", Fmt(Result.UBound()));
	EndDo;
	LoopScope.Break.Clear();
	
	For Each Addr In LoopScope.Continue Do
		Result[Addr] = StrTemplate("IP=%1;", Fmt(HeadAddr));
	EndDo;
	LoopScope.Continue.Clear();
	
	Result.Add("SP=SP-3;For _=SP+1 TO SP+3 Do M[_]=Undefined EndDo;");
	
	CloseLoopScope();
	
EndProcedure // VisitForEachStmt()

Procedure VisitTryStmt(TryStmt)
	
	Result.Add();
	HeadAddr = Result.UBound();
	VisitStatements(TryStmt.Try);
	
	Result.Add();
	JumpAddr = Result.UBound();
	
	Result[HeadAddr] = StrTemplate("EP=EP+1;ES[EP]=%1;EP=EP+1;ES[EP]=SP;", Fmt(Result.UBound()+1));
	VisitStatements(TryStmt.Except.Body);
	
	Result.Add("ES[EP]=Undefined;EP=EP-1;ES[EP]=Undefined;EP=EP-1;");
	Result[JumpAddr] = StrTemplate("IP=%1;", Fmt(Result.UBound()));
	
EndProcedure // VisitTryStmt()

// TODO: нужны области видимости для меток
Procedure VisitGotoStmt(GotoStmt)
	Result.Add();
	List = GotoList[GotoStmt.Label];
	If List = Undefined Then
		List = New Array;
		GotoList[GotoStmt.Label] = List;
	EndIf;
	List.Add(Result.UBound());
EndProcedure // VisitGotoStmt()

Procedure VisitLabelStmt(LabelStmt)
	Labels[LabelStmt.Label] = Result.UBound();
EndProcedure // VisitLabelStmt()

#EndRegion // VisitStmt

#Region VisitExpr

Procedure VisitExpr(Expr, Buffer)
	Var Type, Hook;
	Type = Expr.Type;
	If Type = Nodes.BasicLitExpr Then
		VisitBasicLitExpr(Expr, Buffer);
	ElsIf Type = Nodes.IdentExpr Then
		VisitIdentExpr(Expr, Buffer);
	ElsIf Type = Nodes.UnaryExpr Then
		VisitUnaryExpr(Expr, Buffer);
	ElsIf Type = Nodes.BinaryExpr Then
		VisitBinaryExpr(Expr, Buffer);
	ElsIf Type = Nodes.NewExpr Then
		VisitNewExpr(Expr, Buffer);
	ElsIf Type = Nodes.TernaryExpr Then
		VisitTernaryExpr(Expr, Buffer);
	ElsIf Type = Nodes.ParenExpr Then
		VisitParenExpr(Expr, Buffer);
	ElsIf Type = Nodes.NotExpr Then
		VisitNotExpr(Expr, Buffer);
	ElsIf Type = Nodes.StringExpr Then
		VisitStringExpr(Expr, Buffer);
	EndIf;
EndProcedure // VisitExpr()

Procedure VisitBasicLitExpr(BasicLitExpr, Buffer)
	BasicLitKind = BasicLitExpr.Kind;
	If BasicLitKind = Tokens.String Then
		Buffer.Add(BasicLitExpr.Value);
	ElsIf BasicLitKind = Tokens.StringBeg Then
		Buffer.Add(BasicLitExpr.Value);
	ElsIf BasicLitKind = Tokens.StringMid Then
		Buffer.Add(BasicLitExpr.Value);
	ElsIf BasicLitKind = Tokens.StringEnd Then
		Buffer.Add(BasicLitExpr.Value);
	ElsIf BasicLitKind = Tokens.Number Then
		Buffer.Add(Fmt(BasicLitExpr.Value));
	ElsIf BasicLitKind = Tokens.DateTime Then
		Buffer.Add(StrTemplate("'%1'", Format(BasicLitExpr.Value, "DF=yyyyMMddhhmmss; DE=00010101")));
	ElsIf BasicLitKind = Tokens.True Then
		Buffer.Add("True");
	ElsIf BasicLitKind = Tokens.False Then
		Buffer.Add("False");
	ElsIf BasicLitKind = Tokens.Undefined Then
		Buffer.Add("Undefined");
	ElsIf BasicLitKind = Tokens.Null Then
		Buffer.Add("Null");
	Else
		Raise "Unknown basic literal";
	EndIf;
EndProcedure // VisitBasicLitExpr()

Procedure VisitIdentExpr(IdentExpr, Buffer)	
	
	Decl = IdentExpr.Head.Decl;
	
	If IdentExpr.Args <> Undefined Then		
		
		GenerateCall(IdentExpr, Buffer);
		
	ElsIf Decl = Undefined Then
		
		Buffer.Add(IdentExpr.Head.Name);
		
	Else
		
		Offset = OffsetMap[Decl];
		Type = Decl.Type;
		
		If Type = Nodes.VarModDecl Then
			Buffer.Add(StrTemplate("M[%1]", Fmt(Offset)));	
		Else	
			Buffer.Add(StrTemplate("M[FP+%1]", Fmt(Offset)));
		EndIf; 
		
	EndIf;
	
	VisitTail(IdentExpr.Tail, Buffer);
	
EndProcedure // VisitIdentExpr()

Procedure GenerateCall(IdentExpr, Buffer)
	
	Head = IdentExpr.Head;
	Decl = Head.Decl;
	Args = IdentExpr.Args;
	
	If Decl = Undefined Then
		
		// Вызов нативного метода, т.к. объявление не обнаружено
		
		Buffer.Add(Head.Name);
		If Head.Name <> "ErrorInfo" Then
			Buffer.Add("(");
			VisitExprList(Args, Buffer);
			Buffer.Add(")");
		EndIf; 
		
	Else 
		
		// Вызов интерпретируемого метода 
		
		Params = Decl.Params;
		
		// буфер для пролога
		Prolog = New Array;
		
		// генерация пролога {{
		
		// кадр вызова:
		// -2 Результат функции (для процедур тоже, но игнорится)
		// -1 Адрес возврата
		//  0 Адрес кадра родительской функции
		// +1 Аргумент1 (значение)
		// +2 Аргумент2 (значение)
		// +3 Переменная1 (значение)
		// +4 Переменная2 (значение)
		
		// сохранение указателя инструкции и указателя кадра для возврата
		Prolog.Add("SP=SP+2;M[SP]=IP+1;SP=SP+1;M[SP]=FP;"); 
		
		Index = 0;
		
		TotalArgs = Args.Count();
		
		For Index = 0 To Params.UBound() Do
			
			// формальный параметр
			Param = Params[Index];
			
			// значение соответствующего аргумента
			If Index < TotalArgs Then
				ArgExpr = Args[Index];
			Else // аргумент в конце опущен (TODO: нужно генерить ошибку если он не имеет значения по умолчанию)
				ArgExpr = Undefined;
			EndIf;
			
			If ArgExpr = Undefined Then
				
				// аргумент либо пропущен, либо опущен - нужно взять значение по умолчанию
				ArgExpr = Param.Value; 
				
				If ArgExpr = Undefined Then
					// аргумент не имеет значения по умолчанию - значит Неопределено
					ArgExpr = New Structure("Type, Kind, Value", "BasicLitExpr", Tokens.Undefined, Undefined); 
				EndIf;
				
			EndIf;
			
			Prolog.Add("SP=SP+1;M[SP]=");
			VisitExpr(ArgExpr, Prolog);
			Prolog.Add(";");
			
		EndDo;
		
		// Резервирование места под локальные переменные
		VarsCount = ItemsCount[Decl] - Params.Count();
		If VarsCount > 0 Then
			Prolog.Add(StrTemplate("SP=SP+%1;", Fmt(VarsCount)));
		EndIf; 
		
		// Установка указателя кадра вызываемой процедуры
		Prolog.Add(StrTemplate("FP=SP-%1;", Fmt(ItemsCount[Decl])));
		Prolog.Add(" // allocate: 1 Result, ret IP, parent FP, N args, N vars; New FP");
		
		Result.Add(StrConcat(Prolog));
		
		// вызов
		Result.Add(); // deferred
		List = CallSites[Decl];
		If List = Undefined Then
			List = New Array;
			CallSites[Decl] = List;
		EndIf; 
		List.Add(Result.UBound());
		
		// }} генерация пролога
		
		// нужно вернуть в выражение результат вызова функции
		// адрес результата берется как смещение относительно FP вызывающего метода
		CallsCount = CallsCount + 1;
		Buffer.Add(StrTemplate("M[FP+%1]", ItemsCount[CurrentCaller] + CallsCount));
		
	EndIf; 
	
EndProcedure

Procedure VisitUnaryExpr(UnaryExpr, Buffer)
	Buffer.Add(StrTemplate("%1", Operators[UnaryExpr.Operator]));
	VisitExpr(UnaryExpr.Operand, Buffer);
EndProcedure // VisitUnaryExpr()

Procedure VisitBinaryExpr(BinaryExpr, Buffer)
	VisitExpr(BinaryExpr.Left, Buffer);
	Buffer.Add(Operators[BinaryExpr.Operator]);
	VisitExpr(BinaryExpr.Right, Buffer);
EndProcedure // VisitBinaryExpr()

Procedure VisitNewExpr(NewExpr, Buffer)
	Buffer.Add("New ");
	If NewExpr.Name <> Undefined Then
		Buffer.Add(NewExpr.Name);
	EndIf;
	If NewExpr.Args.Count() > 0 Then
		Buffer.Add("(");
		VisitExprList(NewExpr.Args, Buffer);
		Buffer.Add(")");
	EndIf;
EndProcedure // VisitNewExpr()

Procedure VisitTernaryExpr(TernaryExpr, Buffer)
	Buffer.Add("?(");
	VisitExpr(TernaryExpr.Cond, Buffer);
	Buffer.Add(", ");
	VisitExpr(TernaryExpr.Then, Buffer);
	Buffer.Add(", ");
	VisitExpr(TernaryExpr.Else, Buffer);
	Buffer.Add(")");
	VisitTail(TernaryExpr.Tail, Buffer);
EndProcedure // VisitTernaryExpr()

Procedure VisitParenExpr(ParenExpr, Buffer)
	Buffer.Add("(");
	VisitExpr(ParenExpr.Expr, Buffer);
	Buffer.Add(")");
EndProcedure // VisitParenExpr()

Procedure VisitNotExpr(NotExpr, Buffer)
	Buffer.Add("Not ");
	VisitExpr(NotExpr.Expr, Buffer);
EndProcedure // VisitNotExpr()

Procedure VisitStringExpr(StringExpr, Buffer)
	List = StringExpr.List;
	Buffer.Add("""");
	Buffer.Add(List[0].Value);
	Buffer.Add("""");
	For Index = 1 To List.UBound() Do
		Expr = List[Index];
		Buffer.Add(" """);
		Buffer.Add(Expr.Value);
		Buffer.Add("""");
	EndDo;
EndProcedure // VisitStringExpr()

#EndRegion // VisitExpr

#Region Aux

Function Fmt(Value)
	Return Format(Value, "NZ=0; NG=");
EndFunction

Procedure VisitExprList(ExprList, Buffer)
	If ExprList.Count() > 0 Then
		For Each Expr In ExprList Do
			If Expr = Undefined Then
				Buffer.Add("");
			Else
				VisitExpr(Expr, Buffer);
			EndIf;
			Buffer.Add(", ");
		EndDo;
		Buffer[Buffer.UBound()] = "";
	EndIf;
EndProcedure // VisitExprList()

Procedure VisitTail(Tail, Buffer)
	For Each Item In Tail Do
		If Item.Type = Nodes.FieldExpr Then
			Buffer.Add(".");
			Buffer.Add(Item.Name);
			If Item.Args <> Undefined Then
				Buffer.Add("(");
				VisitExprList(Item.Args, Buffer);
				Buffer.Add(")");
			EndIf;
		ElsIf Item.Type = Nodes.IndexExpr Then
			Buffer.Add("[");
			VisitExpr(Item.Expr, Buffer);
			Buffer.Add("]");
		Else
			Raise "Unknown selector kind";
		EndIf;
	EndDo;  
EndProcedure // VisitTail()

#EndRegion // Aux
