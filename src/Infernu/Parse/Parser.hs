{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | A simple applicative parser
module Infernu.Parse.Parser where



import qualified Data.Char as Char
import           Data.Functor.Identity
import           Infernu.Decycle (decycle)
import           Infernu.Parse.NameRec (Named(..), named, runNamed, Names(..), NameT)

import qualified Data.Map as Map
import           Data.Map (Map)
import           Infernu.Prelude

type Stream a = [a]

emptyStream :: [a]
emptyStream = []

data PElem a b = PElem (Map a b) -- matching characters a map to tokens b
             deriving (Eq, Ord, Show)

-- runPElem :: Eq s => PElem s -> Stream s -> Maybe (Stream s, s)
runPElem :: Ord k => PElem k a -> Stream k -> Maybe (Stream k, a)
runPElem _ [] = Nothing
runPElem (PElem m) (s:ss) = fmap (ss,) $ Map.lookup s m

-- | Transparent, non-applicative alternative. laws:
--
-- naught ^|^ x = x
-- x ^|^ naught = x
--
-- x ^|^ (y ^|^ z) = (x ^|^ y) ^|^ z
--
class WrapAlt f where
    infixl ^|^
    (^|^) :: a -> a -> f a
    naught :: f a

class WrapSeq f where
    infixl <^>
    (<^>) :: a -> a -> f a
    empty :: f a

    infixl <^
    (<^) :: a -> a -> f a

    infixl ^>
    (^>) :: a -> a -> f a
    (^>) = flip (<^)


data Parser s a p where
    PZero      :: Parser s a p
    POneOf     :: PElem s a -> Parser s a p
    PAlt       :: [p] -> Parser s a p
    POneOrMore :: p -> Parser s a p
    PSeq       :: [p] -> Parser s a p
    PFirst     :: p -> p -> Parser s a p

--deriving instance (Show s, Show a) => Show (Parser s a)

type ParserName = Maybe Int
type NamedParser s a = Named ParserName (Parser s a)

emptyNames :: Names ParserName
emptyNames = Names { namesNext = (fmap (+1)), namesCurrent = Nothing }

instance WrapAlt (Parser s a) where
    naught    = PZero
    p1 ^|^ p2 = PAlt [p1, p2]

oneOrMore :: p -> Parser s a p
oneOrMore p  = POneOrMore p

zeroOrMore :: WrapAlt f => a -> f (Parser s b a)
zeroOrMore p = naught ^|^ oneOrMore p

instance WrapSeq (Parser s a) where
    empty   = PSeq []
    x <^> y = PSeq [y,x]
    x <^ y = PFirst x y

fmapParserResult :: (a -> b) -> (s, a) -> (s, b)
fmapParserResult = fmap

type RunParser s a
    = NamedParser s a -> Stream s -> [(Stream s, [a])]

runNamedParserSome :: RunParser s a -> NamedParser s a -> Stream s -> [(Stream s, [a])]
runNamedParserSome r p s = do
    (s', t) <- r p s
    res <- (s', []) : runNamedParserSome r p s'
    return $ fmapParserResult (t++) res

runNamedParserAlt :: RunParser s a ->  [NamedParser s a] -> Stream s -> [(Stream s, [a])]
runNamedParserAlt r ps s = concat $ map (flip r s) ps

runNamedParserSeq :: RunParser s a -> [NamedParser s a] -> Stream s -> [(Stream s, [a])]
runNamedParserSeq r ps stream = foldr flattenSeq [(stream, mempty)] ps
    where
        -- flattenSeq :: NamedParser s a -> [(Stream s, a)] -> [(Stream s, a)]
        flattenSeq p alts = do
            (s, t) <- alts
            (s', t') <- r p s
            return (s', t ++ t')

runNamedParserOneOf :: Ord s => PElem s a -> Stream s -> [(Stream s, [a])]
runNamedParserOneOf p s =
    case runPElem p s of
    Nothing -> []
    Just (s', t) -> [(s', [t])]

runNamedParser'' :: Ord s => RunParser s a -> Parser s a (NamedParser s a) -> Stream s -> [(Stream s, [a])]
--runNamedParser'' _  _    [] = []
runNamedParser'' _  PZero _ = []
runNamedParser'' _ (POneOf p) s = runNamedParserOneOf p s
runNamedParser'' r (POneOrMore p) s = runNamedParserSome r p s
runNamedParser'' r (PAlt ps) s = runNamedParserAlt r ps s
runNamedParser'' r (PSeq ps) s = runNamedParserSeq r ps s
runNamedParser'' r (PFirst x y) s = do
    (s', t) <- r x s
    (s'', _) <- r y s'
    return (s'', t)

runNamedParser' :: Ord s => Maybe (RunParser s a) -> NamedParser s a -> Stream s -> [(Stream s, [a])]
runNamedParser' Nothing _ _ = []
runNamedParser' (Just r) p s = runNamedParser'' r (nameUnwrap p) s

runNamedParser :: Ord s => NamedParser s a -> Stream s -> [(Stream s, [a])]
runNamedParser = decycle runNamedParser'

runParser :: Ord s => Parser s a (NamedParser s a) -> Stream s -> [(Stream s, [a])]
runParser p s = runNamedParser (Named Nothing p) s

type Parse s a = NameT ParserName Identity (NamedParser s a)

anon = Named Nothing

----------------------------------------------------------------------

is :: Ord s => Map s a -> Parser s a p
is = POneOf . PElem

--are :: Ord s => Map s a -> Parser s a p
--are = zeroOrMore . is

-- TODO: Ugh.
allChars :: [Char]
allChars = map Char.chr [0..127]

isChar :: (Char -> Bool) -> a -> NamedParser Char a
isChar f x = anon . is $ foldr (\k -> Map.insert k x) Map.empty $ filter f allChars

lower = isChar Char.isLower
digit = isChar Char.isDigit
upper = isChar Char.isUpper
letter = isChar Char.isLetter
alphaNum = isChar Char.isAlphaNum

isStr s = PSeq $ reverse $ map (isChar . (==)) s

str = oneOrMore letter

space = isChar Char.isSpace

openPar :: a -> NamedParser Char a
openPar = isChar (=='(')

closePar :: a -> NamedParser Char a
closePar = isChar (==')')

infixl <^^>

(<^^>) :: NamedParser c a -> NamedParser c a -> NamedParser c a
x <^^> y = anon $ x <^> y

infixl ^||^
(^||^) :: NamedParser c a -> NamedParser c a -> NamedParser c a
x ^||^ y = anon $ x ^|^ y

--withParens x = runIdentity $ runNamed $ named $ openPar <^> str

--withParens :: Monoid a => NamedParser Char a -> NamedParser Char a
--withParens :: (Monad m, Monoid a, WrapSeq m) => Parse Char a -> m (Parse Char a)
within
    :: Monoid a => (a -> NamedParser c a) -> (a -> NamedParser c a)
    -> NamedParser c a
    -> NamedParser c a
within pre post x = anon $ (anon $ (pre mempty) ^> x) <^ (post mempty)

withParens :: Monoid a => NamedParser Char a -> NamedParser Char a
withParens = within openPar closePar

optParens :: Monoid a => NamedParser Char a -> NamedParser Char a
optParens x = anon $ x ^|^ withParens x

--afix :: (NamedParser a -> NamedParser a) -> NamedParser a
-- afix  p = p (afix p)

-- name = oneOrMore letter

-- -- data Exp = Var String | Lam String Exp | App Exp Expr
-- type Recursive a = a -> a

-- --app :: Recursive (NamedParser a)
-- --app recurse = recurse <?> "func" <^> oneOrMore space <^> recurse <?> "arg"
-- app recurse = recurse <^> oneOrMore space <^> recurse

-- --lam :: Recursive (NamedParser a)
-- lam recurse = isChar (=='\\') <^> name <^> isChar (=='.') <^> recurse

-- --var :: NamedParser a
-- var = name

-- expr = afix $ \recurse -> app recurse ^|^ lam recurse ^|^ var
