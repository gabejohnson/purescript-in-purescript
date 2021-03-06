module Control.Monad.ST where

import Control.Monad.Eff

foreign import data ST :: * -> !

foreign import data STRef :: * -> * -> *

foreign import data STArray :: * -> * -> *

foreign import newSTRef "function newSTRef(val) {\
                        \  return function () {\
                        \    return { value: val };\
                        \  };\
                        \}" :: forall a h r. a -> Eff (st :: ST h | r) (STRef h a)

foreign import readSTRef "function readSTRef(ref) {\
                         \  return function() {\
                         \    return ref.value;\
                         \  };\
                         \}" :: forall a h r. STRef h a -> Eff (st :: ST h | r) a

foreign import modifySTRef "function modifySTRef(ref) {\
                           \  return function(f) {\
                           \    return function() {\
                           \      return ref.value = f(ref.value);\
                           \    };\
                           \  };\
                           \}" :: forall a h r. STRef h a -> (a -> a) -> Eff (st :: ST h | r) a

foreign import writeSTRef "function writeSTRef(ref) {\
                          \  return function(a) {\
                          \    return function() {\
                          \      return ref.value = a;\
                          \    };\
                          \  };\
                          \}" :: forall a h r. STRef h a -> a -> Eff (st :: ST h | r) a

foreign import newSTArray "function newSTArray(len) {\
                          \  return function(a) {\
                          \    return function() {\
                          \      var arr = [];\
                          \      for (var i = 0; i < len; i++) {\
                          \        arr[i] = a;\
                          \      };\
                          \      return arr;\
                          \    };\
                          \  };\
                          \}" :: forall a h r. Number -> a -> Eff (st :: ST h | r) (STArray h a)

foreign import peekSTArray "function peekSTArray(arr) {\
                           \  return function(i) {\
                           \    return function() {\
                           \      return arr[i];\
                           \    };\
                           \  };\
                           \}" :: forall a h r. STArray h a -> Eff (st :: ST h | r) a

foreign import pokeSTArray "function pokeSTArray(arr) {\
                           \  return function(i) {\
                           \    return function(a) {\
                           \      return function() {\
                           \        return arr[i] = a;\
                           \      };\
                           \    };\
                           \  };\
                           \}" :: forall a h r. STArray h a -> Number -> a -> Eff (st :: ST h | r) a

foreign import runST "function runST(f) {\
                     \  return f;\
                     \}" :: forall a r. (forall h. Eff (st :: ST h | r) a) -> Eff r a

foreign import runSTArray "function runSTArray(f) {\
                          \  return f;\
                          \}" :: forall a r. (forall h. Eff (st :: ST h | r) (STArray h a)) -> Eff r [a]
