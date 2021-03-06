{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}

module Hasura.GraphQL.Resolve.BoolExp
  ( parseBoolExp
  , convertBoolExp
  , prepare
  ) where

import           Data.Has
import           Hasura.Prelude

import qualified Data.HashMap.Strict               as Map
import qualified Language.GraphQL.Draft.Syntax     as G

import qualified Hasura.RQL.GBoolExp               as RA
import qualified Hasura.RQL.GBoolExp               as RG
import qualified Hasura.SQL.DML                    as S

import           Hasura.GraphQL.Resolve.Context
import           Hasura.GraphQL.Resolve.InputValue
import           Hasura.GraphQL.Validate.Types
import           Hasura.RQL.Types

import           Hasura.SQL.Types
import           Hasura.SQL.Value

parseOpExps
  :: (MonadError QErr m, MonadReader r m, Has FieldMap r)
  => AnnGValue -> m [RA.OpExp]
parseOpExps annVal = do
  opExpsM <- flip withObjectM annVal $ \nt objM -> forM objM $ \obj ->
    forM (Map.toList obj) $ \(k, v) -> case k of
      "_eq"       -> fmap RA.AEQ <$> asPGColValM v
      "_ne"       -> fmap RA.ANE <$> asPGColValM v
      "_neq"      -> fmap RA.ANE <$> asPGColValM v
      "_is_null"  -> resolveIsNull v

      "_in"       -> fmap (RA.AIN . catMaybes) <$> parseMany asPGColValM v
      "_nin"      -> fmap (RA.ANIN . catMaybes) <$> parseMany asPGColValM v

      "_gt"       -> fmap RA.AGT <$> asPGColValM v
      "_lt"       -> fmap RA.ALT <$> asPGColValM v
      "_gte"      -> fmap RA.AGTE <$> asPGColValM v
      "_lte"      -> fmap RA.ALTE <$> asPGColValM v

      "_like"     -> fmap RA.ALIKE <$> asPGColValM v
      "_nlike"    -> fmap RA.ANLIKE <$> asPGColValM v

      "_ilike"    -> fmap RA.AILIKE <$> asPGColValM v
      "_nilike"   -> fmap RA.ANILIKE <$> asPGColValM v

      "_similar"  -> fmap RA.ASIMILAR <$> asPGColValM v
      "_nsimilar" -> fmap RA.ANSIMILAR <$> asPGColValM v
      _ ->
        throw500
          $  "unexpected operator found in opexp of "
          <> showNamedTy nt
          <> ": "
          <> showName k
  return $ map RA.OEVal $ catMaybes $ fromMaybe [] opExpsM
  where
    resolveIsNull v = case v of
      AGScalar _ Nothing -> return Nothing
      AGScalar _ (Just (PGValBoolean b)) ->
        return $ Just $ bool RA.ANISNOTNULL RA.ANISNULL b
      AGScalar _ _ -> throw500 "boolean value is expected"
      _ -> tyMismatch "pgvalue" v

parseColExp
  :: (MonadError QErr m, MonadReader r m, Has FieldMap r)
  => G.NamedType
  -> G.Name
  -> AnnGValue
  -> m RA.AnnVal
parseColExp nt n val = do
  fldInfo <- getFldInfo nt n
  case fldInfo of
    Left  pgColInfo          -> RA.AVCol pgColInfo <$> parseOpExps val
    Right (relInfo, permExp, _, _) -> do
      relBoolExp <- parseBoolExp val
      return $ RA.AVRel relInfo relBoolExp permExp

parseBoolExp
  :: (MonadError QErr m, MonadReader r m, Has FieldMap r)
  => AnnGValue
  -> m (GBoolExp RA.AnnVal)
parseBoolExp annGVal = do
  boolExpsM <-
    flip withObjectM annGVal
      $ \nt objM -> forM objM $ \obj -> forM (Map.toList obj) $ \(k, v) -> if
          | k == "_or"  -> BoolOr . fromMaybe [] <$> parseMany parseBoolExp v
          | k == "_and" -> BoolAnd . fromMaybe [] <$> parseMany parseBoolExp v
          | k == "_not" -> BoolNot <$> parseBoolExp v
          | otherwise   -> BoolCol <$> parseColExp nt k v
  return $ BoolAnd $ fromMaybe [] boolExpsM

convertBoolExp
  :: QualifiedTable
  -> AnnGValue
  -> Convert (GBoolExp RG.AnnSQLBoolExp)
convertBoolExp tn whereArg = do
  whereExp <- parseBoolExp whereArg
  RG.convBoolRhs (RG.mkBoolExpBuilder prepare) (S.mkQual tn) whereExp
