module Language.PureScript.Optimizer.Inliner
  ( inlineVariables
  , inlineOperator
  , inlineCommonOperators
  , etaConvert
  , unThunk
  , evaluateIifes
  ) where

import Data.Array (map, zipWith)
import Data.Array.Unsafe (last, init)
import Data.Foldable (all, any)
import Data.Maybe
import Data.Tuple
import Language.PureScript.CodeGen.JS.AST
import Language.PureScript.CodeGen.Common (identToJs)
import Language.PureScript.Names
import Language.PureScript.Optimizer.Common

import qualified Language.PureScript.Constants as C

shouldInline :: JS -> Boolean
shouldInline (JSVar _) = true
shouldInline (JSNumericLiteral _) = true
shouldInline (JSStringLiteral _) = true
shouldInline (JSBooleanLiteral _) = true
shouldInline (JSAccessor _ val) = shouldInline val
shouldInline (JSIndexer index val) = shouldInline index && shouldInline val
shouldInline _ = false

etaConvert :: JS -> JS
etaConvert = everywhereOnJS convert
  where
  convert :: JS -> JS
  convert (JSBlock [JSReturn (JSApp (JSFunction Nothing idents block@(JSBlock body)) args)])
    | all shouldInline args &&
      not (any (flip isRebound block) (map JSVar idents)) &&
      not (any (flip isRebound block) args)
      = JSBlock (map (replaceIdents (zipWith Tuple idents args)) body)
  convert js = js

unThunk :: JS -> JS
unThunk = everywhereOnJS convert
  where
  convert :: JS -> JS
  convert (JSBlock []) = JSBlock []
  convert (JSBlock jss) =
    case last jss of
      JSReturn (JSApp (JSFunction Nothing [] (JSBlock body)) []) -> JSBlock $ init jss ++ body
      _ -> JSBlock jss
  convert js = js

evaluateIifes :: JS -> JS
evaluateIifes = everywhereOnJS convert
  where
  convert :: JS -> JS
  convert (JSApp (JSFunction Nothing [] (JSBlock [JSReturn ret])) []) = ret
  convert js = js

inlineVariables :: JS -> JS
inlineVariables = everywhereOnJS $ removeFromBlock go
  where
  go :: [JS] -> [JS]
  go [] = []
  go (JSVariableIntroduction var (Just js) : sts)
    | shouldInline js && not (any (isReassigned var) sts) && not (any (isRebound js) sts) && not (any (isUpdated var) sts) =
      go (map (replaceIdent var js) sts)
  go (s:sts) = s : go sts

inlineOperator :: (Tuple String String) -> (JS -> JS -> JS) -> JS -> JS
inlineOperator (Tuple m op) f = everywhereOnJS convert
  where
  convert :: JS -> JS
  convert (JSApp (JSApp op' [x]) [y]) | isOp op' = f x y
  convert other = other
  isOp (JSAccessor longForm (JSVar m')) = m == m' && longForm == identToJs (Op op)
  isOp (JSIndexer (JSStringLiteral op') (JSVar m')) = m == m' && op == op'
  isOp _ = false

inlineCommonOperators :: JS -> JS
inlineCommonOperators = applyAll
  [ binary         C.numNumber          C.(+)        Add
  , binary         C.numNumber          C.(-)        Subtract
  , binary         C.numNumber          C.(*)        Multiply
  , binary         C.numNumber          C.(/)        Divide
  , binary         C.numNumber          C.(%)        Modulus
  , unary          C.numNumber          C.negate     Negate
                  
  , binary         C.ordNumber          C.(<)        LessThan
  , binary         C.ordNumber          C.(>)        GreaterThan
  , binary         C.ordNumber          C.(<=)       LessThanOrEqualTo
  , binary         C.ordNumber          C.(>=)       GreaterThanOrEqualTo
                  
  , binary         C.eqNumber           C.(==)       EqualTo
  , binary         C.eqNumber           C.(/=)       NotEqualTo
  , binary         C.eqString           C.(==)       EqualTo
  , binary         C.eqString           C.(/=)       NotEqualTo
  , binary         C.eqBoolean          C.(==)       EqualTo
  , binary         C.eqBoolean          C.(/=)       NotEqualTo
                  
  , binary         C.semigroupString    C.(++)       Add

  , binaryFunction C.bitsNumber         C.shl        ShiftLeft
  , binaryFunction C.bitsNumber         C.shr        ShiftRight
  , binaryFunction C.bitsNumber         C.zshr       ZeroFillShiftRight
  , binary         C.bitsNumber         C.(&)        BitwiseAnd
  , binary         C.bitsNumber         C.bar        BitwiseOr
  , binary         C.bitsNumber         C.(^)        BitwiseXor
  , unary          C.bitsNumber         C.complement BitwiseNot

  , binary         C.boolLikeBoolean    C.(&&)       And
  , binary         C.boolLikeBoolean    C.(||)       Or
  , unary          C.boolLikeBoolean    C.not        Not
  ]
  where
  binary :: String -> String -> BinaryOperator -> JS -> JS
  binary dictName opString op = everywhereOnJS convert
    where
    convert :: JS -> JS
    convert (JSApp (JSApp (JSApp fn [dict]) [x]) [y]) | isOp fn && isOpDict dictName dict = JSBinary op x y
    convert other = other
    isOp (JSAccessor longForm (JSAccessor prelude (JSVar _))) = prelude == C.prelude && longForm == identToJs (Op opString)
    isOp (JSIndexer (JSStringLiteral op') (JSVar prelude)) = prelude == C.prelude && opString == op'
    isOp _ = false
  binaryFunction :: String -> String -> BinaryOperator -> JS -> JS
  binaryFunction dictName fnName op = everywhereOnJS convert
    where
    convert :: JS -> JS
    convert (JSApp (JSApp (JSApp fn [dict]) [x]) [y]) | isOp fn && isOpDict dictName dict = JSBinary op x y
    convert other = other
    isOp (JSAccessor fnName' (JSVar prelude)) = prelude == C.prelude && fnName == fnName'
    isOp _ = false
  unary :: String -> String -> UnaryOperator -> JS -> JS
  unary dictName fnName op = everywhereOnJS convert
    where
    convert :: JS -> JS
    convert (JSApp (JSApp fn [dict]) [x]) | isOp fn && isOpDict dictName dict = JSUnary op x
    convert other = other
    isOp (JSAccessor fnName' (JSVar prelude)) = prelude == C.prelude && fnName' == fnName
    isOp _ = false
  isOpDict dictName (JSApp (JSAccessor prop (JSVar prelude)) [JSObjectLiteral []]) = prelude == C.prelude && prop == dictName
  isOpDict _ _ = false
