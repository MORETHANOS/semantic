{-# LANGUAGE ConstraintKinds, DefaultSignatures, MultiParamTypeClasses, ScopedTypeVariables, UndecidableInstances #-}
module Data.Abstract.Evaluatable
( Evaluatable(..)
, MonadEvaluatable
, module X
, require
, load
) where

import Control.Abstract.Addressable as X
import Control.Abstract.Analysis as X
import Control.Abstract.Value as X
import qualified Data.Abstract.Environment as Env
import qualified Data.Abstract.Exports as Exports
import Data.Abstract.FreeVariables as X
import Data.Abstract.Module
import Data.Abstract.ModuleTable
import Data.Abstract.Value
import Data.Functor.Classes
import Data.Proxy
import Data.Semigroup.Foldable
import Data.Semigroup.App
import Data.Term
import Prelude hiding (fail)
import Prologue


-- | The 'Evaluatable' class defines the necessary interface for a term to be evaluated. While a default definition of 'eval' is given, instances with computational content must implement 'eval' to perform their small-step operational semantics.
-- class Evaluatable constr where
--   eval :: ( FreeVariables term
--           , MonadAddressable (LocationFor value) value m
--           , MonadEvaluateModule term value m
--           , MonadValue value m
--           , Show (LocationFor value)
--           , MonadThrow Prelude.String value m
--           )
--        => SubtermAlgebra constr term (m value)
--   default eval :: (MonadThrow Prelude.String value m, Show1 constr) => SubtermAlgebra constr term (m value)
--   eval expr = throwException $ "Eval unspecialized for " ++ liftShowsPrec (const (const id)) (const id) 0 expr ""
--
-- -- | If we can evaluate any syntax which can occur in a 'Union', we can evaluate the 'Union'.
-- instance Apply Evaluatable fs => Evaluatable (Union fs) where
--   eval = Prologue.apply (Proxy :: Proxy Evaluatable) eval
--
-- -- | Evaluating a 'TermF' ignores its annotation, evaluating the underlying syntax.
-- instance Evaluatable s => Evaluatable (TermF s a) where
--   eval = eval . termFOut


-- Instances

-- | '[]' is treated as an imperative sequence of statements/declarations s.t.:
--
--   1. Each statement’s effects on the store are accumulated;
--   2. Each statement can affect the environment of later statements (e.g. by 'modify'-ing the environment); and
--   3. Only the last statement’s return value is returned.
