module Language.PureScript.Optimizer.MagicDo (magicDo) where

import Data.Array (nub, length, filter)
import Data.Array.Unsafe (last, init)
import Data.Foldable (all, elem)
import Data.Maybe
import Data.Maybe.Unsafe (fromJust)
import Data.Tuple

import Language.PureScript.Options
import Language.PureScript.CodeGen.JS.AST
import Language.PureScript.CodeGen.Common (identToJs)
import Language.PureScript.Names

import qualified Language.PureScript.Constants as C

magicDo :: Options -> JS -> JS
magicDo (Options o) | o.noMagicDo = id
magicDo _ = inlineST <<< magicDo'

-- |
-- Inline type class dictionaries for >>= and return for the Eff monad
--
-- E.g.
--
--  Prelude[">>="](dict)(m1)(function(x) {
--    return ...;
--  })
--
-- becomes
--
--  function __do {
--    var x = m1();
--    ...
--  }
--
magicDo' :: JS -> JS
magicDo' = everywhereOnJS undo <<< everywhereOnJSTopDown convert
  where
  -- The name of the function block which is added to denote a do block
  fnName = "__do"
  -- Desugar monomorphic calls to >>= and return for the Eff monad
  convert :: JS -> JS
  -- Desugar return
  convert (JSApp (JSApp ret [val]) []) | isReturn ret = val
  -- Desugar >>
  convert (JSApp (JSApp bind [m]) [JSFunction Nothing ["_"] (JSBlock js)]) | isBind bind && isJSReturn (last js) =
    case last js of JSReturn ret -> JSFunction (Just fnName) [] $ JSBlock (JSApp m [] : init js ++ [JSReturn (JSApp ret [])] )
  -- Desugar >>=
  convert (JSApp (JSApp bind [m]) [JSFunction Nothing [arg] (JSBlock js)]) | isBind bind && isJSReturn (last js) =
    case last js of JSReturn ret -> JSFunction (Just fnName) [] $ JSBlock (JSVariableIntroduction arg (Just (JSApp m [])) : init js ++ [JSReturn (JSApp ret [])] )
  -- Desugar untilE
  convert (JSApp (JSApp f [arg]) []) | isEffFunc C.untilE f =
    JSApp (JSFunction Nothing [] (JSBlock [ JSWhile (JSUnary Not (JSApp arg [])) (JSBlock []), JSReturn (JSObjectLiteral []) ])) []
  -- Desugar whileE
  convert (JSApp (JSApp (JSApp f [arg1]) [arg2]) []) | isEffFunc C.whileE f =
    JSApp (JSFunction Nothing [] (JSBlock [ JSWhile (JSApp arg1 []) (JSBlock [ JSApp arg2 [] ]), JSReturn (JSObjectLiteral []) ])) []
  convert other = other
  -- Check if an expression represents a monomorphic call to >>= for the Eff monad
  isBind (JSApp bindPoly [effDict]) | isBindPoly bindPoly && isEffDict C.bindEffDictionary effDict = true
  isBind _ = false
  -- Check if an expression represents a monomorphic call to return for the Eff monad
  isReturn (JSApp retPoly [effDict]) | isRetPoly retPoly && isEffDict C.monadEffDictionary effDict = true
  isReturn _ = false
  -- Check if an expression represents the polymorphic >>= function
  isBindPoly (JSAccessor prop (JSVar prelude)) = prelude == C.prelude && prop == identToJs (Op C.(>>=))
  isBindPoly (JSIndexer (JSStringLiteral bind) (JSVar prelude)) = prelude == C.prelude && bind == C.(>>=)
  isBindPoly _ = false
  -- Check if an expression represents the polymorphic return function
  isRetPoly (JSAccessor returnEscaped (JSVar prelude)) = prelude == C.prelude && returnEscaped == C.returnEscaped
  isRetPoly (JSIndexer (JSStringLiteral return') (JSVar prelude)) = prelude == C.prelude && return' == C.return
  isRetPoly _ = false
  -- Check if an expression represents a function in the Ef module
  isEffFunc name (JSAccessor name' (JSVar eff)) = eff == C.eff && name == name'
  isEffFunc _ _ = false
  -- Check if an expression represents the Monad Eff dictionary
  isEffDict name (JSApp (JSVar ident) [JSObjectLiteral []]) | ident == name = true
  isEffDict name (JSApp (JSAccessor prop (JSVar eff)) [JSObjectLiteral []]) = eff == C.eff && prop == name
  isEffDict _ _ = false
  -- Remove __do function applications which remain after desugaring
  undo :: JS -> JS
  undo (JSReturn (JSApp (JSFunction (Just ident) [] body) [])) | ident == fnName = body
  undo other = other

  isJSReturn (JSReturn _) = true
  isJSReturn _ = false

-- |
-- Inline functions in the ST module
--
inlineST :: JS -> JS
inlineST = everywhereOnJS convertBlock
  where
  -- Look for runST blocks and inline the STRefs there.
  -- If all STRefs are used in the scope of the same runST, only using { read, write, modify }STRef then
  -- we can be more aggressive about inlining, and actually turn STRefs into local variables.
  convertBlock (JSApp f [arg]) | isSTFunc C.runST f || isSTFunc C.runSTArray f =
    let refs = nub <<< findSTRefsIn $ arg
        usages = findAllSTUsagesIn arg
        allUsagesAreLocalVars = all (\u -> let v = toVar u in isJust v && fromJust v `elem` refs) usages
        localVarsDoNotEscape = all (\r -> length (r `appearingIn` arg) == length (filter (\u -> let v = toVar u in v == Just r) usages)) refs
    in everywhereOnJS (convert (allUsagesAreLocalVars && localVarsDoNotEscape)) arg
  convertBlock other = other
  -- Convert a block in a safe way, preserving object wrappers of references,
  -- or in a more aggressive way, turning wrappers into local variables depending on the
  -- agg(ressive) parameter.
  convert agg (JSApp f [arg]) | isSTFunc C.newSTRef f =
   JSFunction Nothing [] (JSBlock [JSReturn $ if agg then arg else JSObjectLiteral [Tuple C.stRefValue arg]])
  convert agg (JSApp (JSApp f [ref]) []) | isSTFunc C.readSTRef f =
    if agg then ref else JSAccessor C.stRefValue ref
  convert agg (JSApp (JSApp (JSApp f [ref]) [arg]) []) | isSTFunc C.writeSTRef f =
    if agg then JSAssignment ref arg else JSAssignment (JSAccessor C.stRefValue ref) arg
  convert agg (JSApp (JSApp (JSApp f [ref]) [func]) []) | isSTFunc C.modifySTRef f =
    if agg then JSAssignment ref (JSApp func [ref]) else  JSAssignment (JSAccessor C.stRefValue ref) (JSApp func [JSAccessor C.stRefValue ref])
  convert _ (JSApp (JSApp (JSApp f [arr]) [i]) []) | isSTFunc C.peekSTArray f =
    JSIndexer i arr
  convert _ (JSApp (JSApp (JSApp (JSApp f [arr]) [i]) [val]) []) | isSTFunc C.pokeSTArray f =
    JSAssignment (JSIndexer i arr) val
  convert _ other = other
  -- Check if an expression represents a function in the ST module
  isSTFunc name (JSAccessor name' (JSVar st)) = st == C.st && name == name'
  isSTFunc _ _ = false
  -- Find all ST Refs initialized in this block
  findSTRefsIn = everythingOnJS (++) isSTRef
    where
    isSTRef (JSVariableIntroduction ident (Just (JSApp (JSApp f [_]) []))) | isSTFunc C.newSTRef f = [ident]
    isSTRef _ = []
  -- Find all STRefs used as arguments to readSTRef, writeSTRef, modifySTRef
  findAllSTUsagesIn = everythingOnJS (++) isSTUsage
    where
    isSTUsage (JSApp (JSApp f [ref]) []) | isSTFunc C.readSTRef f = [ref]
    isSTUsage (JSApp (JSApp (JSApp f [ref]) [_]) []) | isSTFunc C.writeSTRef f || isSTFunc C.modifySTRef f = [ref]
    isSTUsage _ = []
  -- Find all uses of a variable
  appearingIn ref = everythingOnJS (++) isVar
    where
    isVar e@(JSVar v) | v == ref = [e]
    isVar _ = []
  -- Convert a JS value to a String if it is a JSVar
  toVar (JSVar v) = Just v
  toVar _ = Nothing
