module ShellCheck.Analytics where

import ShellCheck.Parser
import Control.Monad
import Control.Monad.State
import qualified Data.Map as Map
import Data.Char
import Data.List
import Debug.Trace
import Text.Regex

checks = concat [
    map runBasicAnalysis basicChecks
    ,[subshellAssignmentCheck]
    ]

runAllAnalytics = checkList checks
checkList l t m = foldl (\x f -> f t x) m l

runBasicAnalysis f t m = snd $ runState (doAnalysis f t) m
basicChecks = [
    checkUuoc
    ,checkForInQuoted
    ,checkForInLs
    ,checkMissingForQuotes
    ,checkUnquotedExpansions
    ,checkRedirectToSame
    ,checkShorthandIf
    ,checkDollarStar
    ,checkUnquotedDollarAt
    ,checkStderrRedirect
    ,checkMissingPositionalQuotes
    ,checkSingleQuotedVariables
    ,checkUnquotedZN
    ,checkNumberComparisons
    ,checkNoaryWasBinary 
    ]

modifyMap = modify
addNoteFor id note = modifyMap $ Map.adjust (\(Metadata pos notes) -> Metadata pos (note:notes)) id

willSplit x =
  case x of
    T_DollarBraced _ _ -> True
    T_DollarExpansion _ _ -> True
    T_BraceExpansion _ s -> True
    T_NormalWord _ l -> any willSplit l
    T_Literal _ s -> isGlob s
    _ -> False


isGlob str = any (`elem` str) "*?"

makeSimple (T_NormalWord _ [f]) = f
makeSimple (T_Redirecting _ _ f) = f
makeSimple t = t
simplify = doTransform makeSimple

deadSimple (T_NormalWord _ l) = [concat (concatMap (deadSimple) l)]
deadSimple (T_DoubleQuoted _ l) = ["\"" ++(concat (concatMap (deadSimple) l)) ++ "\""]
deadSimple (T_SingleQuoted _ s) = [s]
deadSimple (T_DollarBraced _ _) = ["${VAR}"]
deadSimple (T_DollarArithmetic _ _) = ["${VAR}"]
deadSimple (T_DollarExpansion _ _) = ["${VAR}"]
deadSimple (T_Pipeline _ [x]) = deadSimple x
deadSimple (T_Literal _ x) = [x]
deadSimple (T_SimpleCommand _ vars words) = concatMap (deadSimple) words
deadSimple (T_Redirecting _ _ foo) = deadSimple foo
deadSimple _ = []

verify f s = checkBasic f s == Just True
verifyNot f s = checkBasic f s == Just False
verifyFull f s = checkFull f s == Just True
verifyNotFull f s = checkFull f s == Just False

checkBasic f s = checkFull (runBasicAnalysis f) s
checkFull f s = case parseShell "-" s of
        (ParseResult (Just (t, m)) _) -> Just . not $ (notesFromMap $ f t m) == (notesFromMap m)
        _ -> Nothing



prop_checkUuoc = verify checkUuoc "cat foo | grep bar"
checkUuoc (T_Pipeline _ (T_Redirecting _ _ f@(T_SimpleCommand id _ _):_:_)) =
    case deadSimple f of ["cat", _] -> addNoteFor id $ Note StyleC "Useless cat. Consider 'cmd < file | ..' or 'cmd file | ..' instead."
                         _ -> return ()
checkUuoc _ = return ()


isMagicInQuotes (T_DollarBraced _ s) | '@' `elem` s = True
isMagicInQuotes _ = False

prop_checkForInQuoted = verify checkForInQuoted "for f in \"$(ls)\"; do echo foo; done"
prop_checkForInQuoted2 = verifyNot checkForInQuoted "for f in \"$@\"; do echo foo; done"
checkForInQuoted (T_ForIn _ f [T_NormalWord _ [T_DoubleQuoted id list]] _) =
    when (any (\x -> willSplit x && not (isMagicInQuotes x)) list) $
        addNoteFor id $ Note ErrorC $ "Since you double quoted this, it will not word split, and the loop will only run once"
checkForInQuoted _ = return ()


prop_checkForInLs = verify checkForInLs "for f in $(ls *.mp3); do mplayer \"$f\"; done"
checkForInLs (T_ForIn _ f [T_NormalWord _ [T_DollarExpansion id [x]]] _) =
    case deadSimple x of ("ls":n) -> let args = (if n == [] then ["*"] else n) in
                                        addNoteFor id $ Note ErrorC $ "Don't use 'for "++f++" in $(ls " ++ (intercalate " " n) ++ ")'. Use 'for "++f++" in "++ (intercalate " " args) ++ "'"
                         _ -> return ()
checkForInLs _ = return ()


prop_checkMissingForQuotes = verify checkMissingForQuotes "for f in *.mp3; do rm $f; done"
prop_checkMissingForQuotes2 = verifyNot checkMissingForQuotes "for f in foo bar; do rm $f; done"
checkMissingForQuotes (T_ForIn _ f words cmds) =
    if not $ any willSplit words then return () else do
        mapM_  (doAnalysis (markUnquoted f)) cmds
  where
    markUnquoted f (T_NormalWord _ l) = mapM_ mu l
    markUnquoted _ _ = return ()
    mu (T_DollarBraced id s) | s == f = warning id
    mu _ = return ()
    warning id = addNoteFor id $ Note WarningC $ "Variables that could contain spaces should be quoted"
checkMissingForQuotes _ = return ()

prop_checkMissingPositionalQuotes = verify checkMissingPositionalQuotes "rm $1"
prop_checkMissingPositionalQuotes2 = verify checkMissingPositionalQuotes "rm ${10//foo/bar}"
checkMissingPositionalQuotes (T_NormalWord _ list) =
    mapM_ checkPos list
    where checkPos (T_DollarBraced id s) | all isDigit (getBracedReference s) = 
            addNoteFor id $ Note WarningC $ "Positional parameters should be quoted to avoid whitespace trouble"
          checkPos _ = return ()
checkMissingPositionalQuotes _ = return ()

prop_checkUnquotedExpansions = verify checkUnquotedExpansions "rm $(ls)"
checkUnquotedExpansions (T_SimpleCommand _ _ cmds) = mapM_ check cmds
    where check (T_NormalWord _ [T_DollarExpansion id _]) = addNoteFor id $ Note WarningC "Quote the expansion to prevent word splitting"
          check _ = return ()
checkUnquotedExpansions _ = return ()

prop_checkRedirectToSame = verify checkRedirectToSame "cat foo > foo"
prop_checkRedirectToSame2 = verify checkRedirectToSame "cat lol | sed -e 's/a/b/g' > lol"
prop_checkRedirectToSame3 = verifyNot checkRedirectToSame "cat lol | sed -e 's/a/b/g' > foo.bar && mv foo.bar lol"
checkRedirectToSame s@(T_Pipeline _ list) =
    mapM_ (\l -> (mapM_ (\x -> doAnalysis (checkOccurences x) l) (getAllRedirs list))) list
  where checkOccurences (T_NormalWord exceptId x) (T_NormalWord newId y) =
            when (x == y && exceptId /= newId) (do
                let note = Note InfoC $ "Make sure not to read and write the same file in the same pipeline"
                addNoteFor newId $ note
                addNoteFor exceptId $ note)
        checkOccurences _ _ = return ()
        getAllRedirs l = concatMap (\(T_Redirecting _ ls _) -> concatMap getRedirs ls) l
        getRedirs (T_FdRedirect _ _ (T_IoFile _ op file)) =
                case op of T_Greater _ -> [file]
                           T_Less _    -> [file]
                           T_DGREAT _  -> [file]
                           _ -> []
        getRedirs _ = []
checkRedirectToSame _ = return ()


prop_checkShorthandIf  = verify checkShorthandIf "[[ ! -z file ]] && scp file host || rm file"
prop_checkShorthandIf2 = verifyNot checkShorthandIf "[[ ! -z file ]] && { scp file host || echo 'Eek'; }"
checkShorthandIf (T_AndIf id _ (T_OrIf _ _ _)) =
    addNoteFor id $ Note InfoC "Note that A && B || C is not if-then-else. C may run when A is true."
checkShorthandIf _ = return ()


prop_checkDollarStar = verify checkDollarStar "for f in $*; do ..; done"
checkDollarStar (T_NormalWord _ [(T_DollarBraced id "*")]) =
    addNoteFor id $ Note WarningC $ "Use \"$@\" (with quotes) to prevent whitespace problems"
checkDollarStar _ = return ()


prop_checkUnquotedDollarAt = verify checkUnquotedDollarAt "ls $@"
prop_checkUnquotedDollarAt2 = verifyNot checkUnquotedDollarAt "ls \"$@\""
checkUnquotedDollarAt (T_NormalWord _ [T_DollarBraced id "@"]) =
    addNoteFor id $ Note ErrorC $ "Add double quotes around $@, otherwise it's just like $* and breaks on spaces"
checkUnquotedDollarAt _ = return ()

prop_checkStderrRedirect = verify checkStderrRedirect "test 2>&1 > cow"
prop_checkStderrRedirect2 = verifyNot checkStderrRedirect "test > cow 2>&1"
checkStderrRedirect (T_Redirecting _ [
    T_FdRedirect id "2" (T_IoFile _ (T_GREATAND _) (T_NormalWord _ [T_Literal _ "1"])),
    T_FdRedirect _ _ (T_IoFile _ op _)
    ] _) = case op of
            T_Greater _ -> error
            T_DGREAT _ -> error
            _ -> return ()
         where error = addNoteFor id $ Note ErrorC $ "The order of the 2>&1 and the redirect matters. The 2>&1 has to be last."
checkStderrRedirect _ = return ()

lt x = trace ("FAILURE " ++ (show x)) x


prop_checkSingleQuotedVariables = verify checkSingleQuotedVariables "echo '$foo'"
prop_checkSingleQuotedVariables2 = verify checkSingleQuotedVariables "echo 'lol$1.jpg'"
prop_checkSingleQuotedVariables3 = verifyNot checkSingleQuotedVariables "sed 's/foo$/bar/'"
checkSingleQuotedVariables (T_SingleQuoted id s) =
            case matchRegex checkSingleQuotedVariablesRe s of
                Just [var] -> addNoteFor id $ Note WarningC $ var ++ " won't be expanded in single quotes."
                _          -> return ()
checkSingleQuotedVariables _ = return ()
checkSingleQuotedVariablesRe = mkRegex "(\\$[0-9a-zA-Z_]+)"


prop_checkUnquotedZN = verify checkUnquotedZN "if [ -z $foo ]; then echo cow; fi"
prop_checkUnquotedZN2 = verify checkUnquotedZN "[ -n $cow ]"
prop_checkUnquotedZN3 = verifyNot checkUnquotedZN "[[ -z $foo ]] && echo cow"
checkUnquotedZN (T_Condition _ SingleBracket (TC_Unary _ SingleBracket op (T_NormalWord id [t]))) | ( op == "-z" || op == "-n" ) && willSplit t =
       addNoteFor id $ Note ErrorC "Always true because you failed to quote. Use [[ ]] instead."
checkUnquotedZN _ = return ()

prop_checkNumberComparisons1 = verify checkNumberComparisons "[[ $foo < 3 ]]"
prop_checkNumberComparisons2 = verify checkNumberComparisons "[[ 0 >= $(cmd) ]]"
prop_checkNumberComparisons3 = verifyNot checkNumberComparisons "[[ $foo ]] > 3"
prop_checkNumberComparisons4 = verify checkNumberComparisons "[ $foo > $bar ]"
prop_checkNumberComparisons5 = verify checkNumberComparisons "until [ $n <= $z ]; do echo foo; done"
checkNumberComparisons (TC_Binary id typ op lhs rhs) 
    | op `elem` ["<", ">", "<=", ">="] = do
        when (isNum lhs || isNum rhs) $ addNoteFor id $ Note ErrorC $ "\"" ++ op ++ "\" is for string comparisons. Use " ++ (eqv op)
        when (typ == SingleBracket) $ addNoteFor id $ Note ErrorC $ "Can't use " ++ op ++" in [ ]. Use [[ ]]."
    where
        isNum t = case deadSimple t of [v] -> all isDigit v
                                       _ -> False
        eqv "<" = "-lt"
        eqv ">" = "-gt"
        eqv "<=" = "-le"
        eqv ">=" = "-ge"
        eqv _ = "the numerical equivalent"
checkNumberComparisons _ = return ()

prop_checkNoaryWasBinary = verify checkNoaryWasBinary "[[ a==$foo ]]"
prop_checkNoaryWasBinary2 = verify checkNoaryWasBinary "[ $foo=3 ]"
checkNoaryWasBinary (TC_Noary _ _ t@(T_NormalWord id l)) = do
    let str = concat $ deadSimple t
    when ('=' `elem` str) $ addNoteFor id $ Note ErrorC $ "Always true because you didn't put spaces around the ="
checkNoaryWasBinary _ = return ()

allModifiedVariables t = snd $ runState (doAnalysis (\x -> modify $ (++) (getModifiedVariables x)) t) []

--- Subshell detection

prop_subshellAssignmentCheck = verifyFull     subshellAssignmentCheck "cat foo | while read bar; do a=$bar; done; echo \"$a\""
prop_subshellAssignmentCheck2 = verifyNotFull subshellAssignmentCheck "while read bar; do a=$bar; done < file; echo \"$a\""
prop_subshellAssignmentCheck3 = verifyFull    subshellAssignmentCheck "( A=foo; ); rm $A"
prop_subshellAssignmentCheck4 = verifyNotFull subshellAssignmentCheck "( A=foo; rm $A; )"
prop_subshellAssignmentCheck5 = verifyFull    subshellAssignmentCheck "cat foo | while read cow; do true; done; echo $cow;"
prop_subshellAssignmentCheck6 = verifyFull    subshellAssignmentCheck "( export lol=$(ls); ); echo $lol;"
subshellAssignmentCheck t map =
    let flow = getVariableFlow t
        check = findSubshelled flow [("oops",[])] Map.empty 
    in snd $ runState check map


data Scope = SubshellScope String | NoneScope deriving (Show, Eq)
data StackData = StackScope Scope | StackScopeEnd | Assignment (Id, String) | Reference (Id, String) deriving (Show, Eq)
data VariableState = Dead Id String | Alive deriving (Show, Eq)

leadType t = 
    case t of
        T_DollarExpansion _ _  -> SubshellScope "$(..) expansion"
        T_Backgrounded _ _  -> SubshellScope "backgrounding &"
        T_Subshell _ _  -> SubshellScope "(..) group"
        -- This considers the whole pipeline one subshell. Consider fixing.
        T_Pipeline _ (_:_:[])  -> SubshellScope "pipeline"
        _ -> NoneScope
        

getModifiedVariables t =
    case t of 
        T_SimpleCommand _ vars [] -> 
            concatMap (\x -> case x of 
                                T_Assignment id name _ -> [(id, name)]
                                _ -> []
                      ) vars
        c@(T_SimpleCommand _ _ _) -> 
            getModifiedVariableCommand c

        --Points to 'for' rather than variable
        T_ForIn id str _ _ -> [(id, str)] 
        _ -> []

getModifiedVariableCommand (T_SimpleCommand _ _ ((T_NormalWord _ ((T_Literal _ x):_)):rest)) = 
    case x of 
        "read" -> concatMap getLiteral rest
        "export" -> concatMap exportParamToLiteral rest
        _ -> []
getModifiedVariableCommand _ = [] 

getLiteral (T_NormalWord _ [T_Literal id s]) = [(id,s)]
getLiteral (T_NormalWord _ [T_DoubleQuoted _ [T_Literal id s]]) = [(id,s)]
getLiteral x = []

exportParamToLiteral (T_NormalWord _ ((T_Literal id s):_)) =
    [(id,prefix)] 
    where prefix = takeWhile (/= '=') s
exportParamToLiteral _ = []

-- TODO:
getBracedReference s = takeWhile (\x -> not $ x `elem` ":[#%/^,") $ dropWhile (== '#') s

getReferencedVariables t =
    case t of 
        T_DollarBraced id str -> map (\x -> (id, x)) $ [getBracedReference str]
        T_Arithmetic _ _ -> [] -- TODO
        _ -> []


startScope t = 
    let scopeType = leadType t
        written = getModifiedVariables t
        read    = getReferencedVariables t
    in do
        when (scopeType /= NoneScope) $ modify ((StackScope scopeType):)
        mapM_ (\v -> modify ((Assignment v):)) written
        mapM_ (\v -> modify ((Reference v):)) read

endScope t =
    let scopeType = leadType t
    in do
        when (scopeType /= NoneScope) $ modify ((StackScopeEnd):)

getVariableFlow t = 
    let (_, stack) = runState (doStackAnalysis startScope endScope t) [] 
    in reverse stack

findSubshelled :: [StackData] -> [(String, [(Id,String)])] -> (Map.Map String VariableState) -> State (Map.Map Id Metadata) ()
findSubshelled [] _ _ = return ()
findSubshelled ((Assignment x@(id, str)):rest) ((reason,scope):lol) deadVars = 
    findSubshelled rest ((reason, x:scope):lol) $ Map.insert str Alive deadVars
findSubshelled ((Reference (readId, str)):rest) scopes deadVars = do
    case Map.findWithDefault Alive str deadVars of 
        Alive -> return ()
        Dead writeId reason -> do
                    addNoteFor writeId $ Note InfoC $ "Modification of " ++ str ++ " is local (to subshell caused by "++ reason ++")."
                    addNoteFor readId $ Note InfoC $ str ++ " was modified in a subshell. That change might be lost."
    findSubshelled rest scopes deadVars

findSubshelled ((StackScope (SubshellScope reason)):rest) scopes deadVars = 
    findSubshelled rest ((reason,[]):scopes) deadVars 

findSubshelled ((StackScopeEnd):rest) ((reason, scope):oldScopes) deadVars = 
    findSubshelled rest oldScopes $ foldl (\m (id, var) -> Map.insert var (Dead id reason) m) deadVars scope 
------
