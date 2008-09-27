-- | Text.ProtocolBuffers.Resolve takes the output of Text.ProtocolBuffers.Parse and runs all
-- the preprocessing and sanity checks that precede Text.ProtocolBuffers.Gen creating modules.
--
-- Currently this involves mangling the names, building a NameSpace (or [NameSpace]), and making
-- all the names fully qualified (and setting TYPE_MESSAGE or TYPE_ENUM) as appropriate.
-- Field names are also checked against a list of reserved words, appending a single quote
-- to disambiguate.
-- All names from Parser should start with a letter, but _ is also handled by replacing with U' or u'.
-- Anything else will trigger a "subborn ..." error.
-- Name resolution failure are not handled elegantly: it will kill the system with a long error message.
--
-- TODO: treat names with leading "." as already "fully-qualified"
--       make sure the optional fields that will be needed are not Nothing (or punt to Reflections.hs)
--       look for repeated use of the same name (before and after mangling)
module Text.ProtocolBuffers.ProtoCompile.Resolve(loadProto,resolveFDP) where

import qualified Text.DescriptorProtos.DescriptorProto                as D(DescriptorProto)
import qualified Text.DescriptorProtos.DescriptorProto                as D.DescriptorProto(DescriptorProto(..))
import qualified Text.DescriptorProtos.DescriptorProto.ExtensionRange as D(ExtensionRange(ExtensionRange))
import qualified Text.DescriptorProtos.DescriptorProto.ExtensionRange as D.ExtensionRange(ExtensionRange(..))
import qualified Text.DescriptorProtos.EnumDescriptorProto            as D(EnumDescriptorProto)
import qualified Text.DescriptorProtos.EnumDescriptorProto            as D.EnumDescriptorProto(EnumDescriptorProto(..))
import qualified Text.DescriptorProtos.EnumValueDescriptorProto       as D(EnumValueDescriptorProto)
import qualified Text.DescriptorProtos.EnumValueDescriptorProto       as D.EnumValueDescriptorProto(EnumValueDescriptorProto(..))
import qualified Text.DescriptorProtos.FieldDescriptorProto           as D.FieldDescriptorProto(FieldDescriptorProto(..))
import qualified Text.DescriptorProtos.FieldDescriptorProto.Type      as D.FieldDescriptorProto(Type)
import           Text.DescriptorProtos.FieldDescriptorProto.Type      as D.FieldDescriptorProto.Type(Type(..))
import qualified Text.DescriptorProtos.FileDescriptorProto            as D(FileDescriptorProto(FileDescriptorProto))
import qualified Text.DescriptorProtos.FileDescriptorProto            as D.FileDescriptorProto(FileDescriptorProto(..))
import qualified Text.DescriptorProtos.FileOptions                    as D.FileOptions(FileOptions(..))
import qualified Text.DescriptorProtos.MethodDescriptorProto          as D(MethodDescriptorProto)
import qualified Text.DescriptorProtos.MethodDescriptorProto          as D.MethodDescriptorProto(MethodDescriptorProto(..))
import qualified Text.DescriptorProtos.ServiceDescriptorProto         as D.ServiceDescriptorProto(ServiceDescriptorProto(..))

import Text.ProtocolBuffers.Header
import Text.ProtocolBuffers.ProtoCompile.Parser

import Control.Monad.State
import Data.Char
import Data.Ix(inRange)
import qualified Data.Foldable as F
import qualified Data.Set as Set
import Data.Maybe(fromMaybe,catMaybes)
import Data.Monoid(Monoid(..))
import Data.Map(Map)
import qualified Data.Map as M
import Data.List(unfoldr,span,inits,foldl')
import qualified Data.ByteString.Lazy.UTF8 as U
import qualified Data.ByteString.Lazy.Char8 as LC
import System.Directory
import System.FilePath

err :: forall b. String -> b
err s = error $ "Text.ProtocolBuffers.Resolve fatal error encountered, message:\n"++indent s
  where indent = unlines . map (\str -> ' ':' ':str) . lines

encodeModuleNames :: [String] -> Utf8
encodeModuleNames [] = Utf8 mempty
encodeModuleNames xs = Utf8 . U.fromString . foldr1 (\a b -> a ++ '.':b) $ xs

mangleCap :: Maybe Utf8 -> [String]
mangleCap = mangleModuleNames . fromMaybe (Utf8 mempty)
  where mangleModuleNames :: Utf8 -> [String]
        mangleModuleNames bs = map mangleModuleName . splitDot . toString $ bs
        splitDot :: String -> [String]
        splitDot = unfoldr s where
          s ('.':xs) = s xs
          s [] = Nothing
          s xs = Just (span ('.'/=) xs)

mangleCap1 :: Maybe Utf8 -> String
mangleCap1 Nothing = ""
mangleCap1 (Just u) = mangleModuleName . toString $ u

mangleEnums :: Seq D.EnumValueDescriptorProto -> Seq D.EnumValueDescriptorProto
mangleEnums s =  fmap fixEnum s
  where fixEnum v = v { D.EnumValueDescriptorProto.name = mangleEnum (D.EnumValueDescriptorProto.name v)}

mangleEnum :: Maybe Utf8 -> Maybe Utf8
mangleEnum = fmap (Utf8 . U.fromString . mangleModuleName . toString)

mangleModuleName :: String -> String
mangleModuleName [] = "Empty'Name" -- XXX
mangleModuleName ('_':xs) = "U'"++xs
mangleModuleName (x:xs) | isLower x = let x' = toUpper x
                                      in if isLower x' then err ("subborn lower case"++show (x:xs))
                                           else x': xs
mangleModuleName xs = xs

mangleFieldName :: Maybe Utf8 -> Maybe Utf8
mangleFieldName = fmap (Utf8 . U.fromString . fixname . toString)
  where fixname [] = "empty'name" -- XXX
        fixname ('_':xs) = "u'"++xs
        fixname (x:xs) | isUpper x = let x' = toLower x
                                     in if isUpper x' then err ("stubborn upper case: "++show (x:xs))
                                          else fixname (x':xs)
        fixname xs | xs `elem` reserved = xs ++ "'"
        fixname xs = xs
        reserved :: [String]
        reserved = ["case","class","data","default","deriving","do","else","foreign"
                   ,"if","import","in","infix","infixl","infixr","instance"
                   ,"let","module","newtype","of","then","type","where"] -- also reserved is "_"

checkER :: [(Int32,Int32)] -> Int32 -> Bool
checkER ers fid = any (`inRange` fid) ers

extRangeList :: D.DescriptorProto -> [(Int32,Int32)]
extRangeList d = concatMap check unchecked
  where check x@(lo,hi) | hi < lo = []
                        | hi<19000 || 19999<lo  = [x]
                        | otherwise = concatMap check [(lo,18999),(20000,hi)]
        unchecked = F.foldr ((:) . extToPair) [] (D.DescriptorProto.extension_range d)
        extToPair (D.ExtensionRange
                    { D.ExtensionRange.start = start
                    , D.ExtensionRange.end = end }) =
          (getFieldId $ maybe minBound FieldId start, getFieldId $ maybe maxBound FieldId end)

newtype NameSpace = NameSpace {unNameSpace::(Map String ([String],NameType,Maybe NameSpace))}
  deriving (Show,Read)
data NameType = Message [(Int32,Int32)] | Enumeration [Utf8] | Service | Void 
  deriving (Show,Read)

type Context = [NameSpace]

seeContext :: Context -> [String] 
seeContext cx = map ((++"[]") . concatMap (\k -> show k ++ ", ") . M.keys . unNameSpace) cx

toString :: Utf8 -> String
toString = U.toString . utf8

findFile :: [FilePath] -> FilePath -> IO (Maybe FilePath)
findFile paths target = do
  let test [] = return Nothing
      test (path:rest) = do
        let fullname = combine path target
        found <- doesFileExist fullname
        if found then return (Just fullname)
          else test rest
  test paths

-- loadProto is a slight kludge.  It takes a single search directory
-- and an initial .proto file path relative to this directory.  It
-- loads this file and then chases the imports.  If an import loop is
-- detected then it aborts.  A state monad is used to memorize
-- previous invocations of 'load'.  A progress message of the filepath
-- is printed before reading a new .proto file.
--
-- The "contexts" collected and used to "resolveWithContext" can
-- contain duplicates: File A imports B and C, and File B imports C
-- will cause the context for C to be included twice in contexts.
--
-- The result type of loadProto is enough for now, but may be changed
-- in the future.  It returns a map from the files (relative to the
-- search directory) to a pair of the resolved descriptor and a set of
-- directly imported files.  The dependency tree is thus implicit.
loadProto :: [FilePath] -> FilePath -> IO (Map FilePath (D.FileDescriptorProto,Set.Set FilePath,[String]))
loadProto protoDirs protoFile = fmap answer $ execStateT (load Set.empty protoFile) mempty where
  answer built = fmap snd built -- drop the fst Context from the pair in the memorized map
  loadFailed f msg = fail . unlines $ ["Parsing proto:",f,"has failed with message",msg]
  load :: Set.Set FilePath  -- set of "parents" that is used by load to detect an import loop. Not memorized.
       -> FilePath          -- the FilePath to load and resolve (may used memorized result of load)
       -> StateT (Map FilePath (Context,(D.FileDescriptorProto,Set.Set FilePath,[String]))) -- memorized results of load
                 IO (Context  -- Only used during load. This is the view of the file as an imported namespace.
                    ,(D.FileDescriptorProto  -- This is the resolved version of the FileDescriptorProto
                     ,Set.Set FilePath
                     ,[String]))  -- This is the list of file directly imported by the FilePath argument
  load parentsIn file = do
    built <- get -- to check memorized results
    when (Set.member file parentsIn)
         (loadFailed file (unlines ["imports failed: recursive loop detected"
                                   ,unlines . map show . M.assocs $ built,show parentsIn]))
    let parents = Set.insert file parentsIn
    case M.lookup file built of
      Just result -> return result
      Nothing -> do
        mayToRead <- liftIO $ findFile protoDirs file
        when (Nothing == mayToRead) $
           loadFailed file (unlines (["loading failed, could not find file: "++show file
                                     ,"Searched paths were:"] ++ map ("  "++) protoDirs))
        let (Just toRead) = mayToRead
        proto <- liftIO $ do print ("Loading filepath: "++toRead)
                             LC.readFile toRead
        parsed <- either (loadFailed toRead . show) return (parseProto toRead proto)
        let (context,imports,names) = toContext parsed
        contexts <- fmap (concatMap fst)    -- keep only the fst Context's
                    . mapM (load parents)   -- recursively chase imports
                    . Set.toList $ imports
        let result = ( withPackage context parsed ++ contexts
                     , ( resolveWithContext (context++contexts) parsed
                       , imports
                       , names ) )
        -- add to memorized results, the "load" above may have updated/invalidated the "built <- get" state above
        modify (\built' -> M.insert file result built')
        return result

-- Imported names must be fully qualified in the .proto file by the
-- target's package name, but the resolved name might be fully
-- quilified by something else (e.g. one of the java options).
withPackage :: Context -> D.FileDescriptorProto -> Context
withPackage (cx:_) (D.FileDescriptorProto {D.FileDescriptorProto.package=Just package}) =
  let prepend = mangleCap1 . Just $ package
  in [NameSpace (M.singleton prepend ([prepend],Void,Just cx))]
withPackage (_:_) (D.FileDescriptorProto {D.FileDescriptorProto.name=n}) =  err $
  "withPackage given an imported FDP without a package declaration: "++show n
withPackage [] (D.FileDescriptorProto {D.FileDescriptorProto.name=n}) =  err $
  "withPackage given an empty context: "++show n

resolveFDP :: D.FileDescriptorProto.FileDescriptorProto
           -> (D.FileDescriptorProto.FileDescriptorProto, [String])
resolveFDP fdpIn =
  let (context,_,names) = toContext fdpIn
  in (resolveWithContext context fdpIn,names)
  
-- process to get top level context for FDP and list of its imports
toContext :: D.FileDescriptorProto -> (Context,Set.Set FilePath,[String])
toContext protoIn =
  let prefix :: [String]
      prefix = mangleCap . msum $
                 [ D.FileOptions.java_outer_classname =<< (D.FileDescriptorProto.options protoIn)
                 , D.FileOptions.java_package =<< (D.FileDescriptorProto.options protoIn)
                 , D.FileDescriptorProto.package protoIn]
      -- Make top-most root NameSpace
      nameSpace = fromMaybe (NameSpace mempty) $ foldr addPrefix protoNames $ zip prefix (tail (inits prefix))
        where addPrefix (s1,ss) ns = Just . NameSpace $ M.singleton s1 (ss,Void,ns)
              protoNames | null protoMsgs = Nothing
                         | otherwise = Just . NameSpace . M.fromList $ protoMsgs
                where protoMsgs = F.foldr ((:) . msgNames prefix) protoEnums (D.FileDescriptorProto.message_type protoIn)
                      protoEnums = F.foldr ((:) . enumNames prefix) protoServices (D.FileDescriptorProto.enum_type protoIn)
                      protoServices = F.foldr ((:) . serviceNames prefix) [] (D.FileDescriptorProto.service protoIn)
                      msgNames context dIn =
                        let s1 = mangleCap1 (D.DescriptorProto.name dIn)
                            ss' = context ++ [s1]
                            dNames | null dMsgs = Nothing
                                   | otherwise = Just . NameSpace . M.fromList $ dMsgs
                            dMsgs = F.foldr ((:) . msgNames ss') dEnums (D.DescriptorProto.nested_type dIn)
                            dEnums = F.foldr ((:) . enumNames ss') [] (D.DescriptorProto.enum_type dIn)
                        in ( s1 , (ss',Message (extRangeList dIn),dNames) )
                      enumNames context eIn = -- XXX todo mangle enum names ? No
                        let s1 = mangleCap1 (D.EnumDescriptorProto.name eIn)
                            values :: [Utf8]
                            values = catMaybes $ map D.EnumValueDescriptorProto.name (F.toList (D.EnumDescriptorProto.value eIn))
                        in ( s1 , (context ++ [s1],Enumeration values,Nothing) )
                      serviceNames context sIn =
                        let s1 = mangleCap1 (D.ServiceDescriptorProto.name sIn)
                        in ( s1 , (context ++ [s1],Service,Nothing) )
      -- Context stack for resolving the top level declarations
      protoContext :: Context
      protoContext = foldl' (\nss@(NameSpace ns:_) pre -> case M.lookup pre ns of
                                                            Just (_,Void,Just ns1) -> (ns1:nss)
                                                            _ -> nss) [nameSpace] prefix
  in ( protoContext
     , Set.fromList (map toString (F.toList (D.FileDescriptorProto.dependency protoIn)))
     , prefix
     )

resolveWithContext :: Context -> D.FileDescriptorProto -> D.FileDescriptorProto
resolveWithContext protoContext protoIn =
  let rerr msg = err $ "Failure while resolving file descriptor proto whose name is "
                       ++ maybe "<empty name>" toString (D.FileDescriptorProto.name protoIn)++"\n"
                       ++ msg
      descend :: Context -> Maybe Utf8 -> Context -- XXX todo take away the maybe 
      descend cx@(NameSpace n:_) name =
        case M.lookup mangled n of
          Just (_,_,Nothing) -> cx
          Just (_,_,Just ns1) -> ns1:cx
          x -> rerr $ "*** Name resolution failed when descending:\n"++unlines (mangled : show x : "KNOWN NAMES" : seeContext cx)
       where mangled = mangleCap1 name -- XXX empty on nothing?
      descend [] _ = []
      resolve :: Context -> Maybe Utf8 -> Maybe Utf8
      resolve _context Nothing = Nothing
      resolve context (Just bs) = fmap fst (resolveWithNameType context bs)
      resolveWithNameType :: Context -> Utf8 -> Maybe (Utf8,NameType)
      resolveWithNameType context bsIn =
        let nameIn = mangleCap (Just bsIn)
            errMsg = "*** Name resolution failed:\n"
                     ++unlines ["Unmangled name: "++show bsIn
                               ,"Mangled name: "++show nameIn
                               ,"List of known names:"]
                     ++ unlines (seeContext context)
            resolver [] (NameSpace _cx) = rerr $ "Impossible? case in Text.ProtocolBuffers.Resolve.resolveWithNameType.resolver []\n" ++ errMsg
            resolver [name] (NameSpace cx) = case M.lookup name cx of
                                               Nothing -> Nothing
                                               Just (fqName,nameType,_) -> Just (encodeModuleNames fqName,nameType)
            resolver (name:rest) (NameSpace cx) = case M.lookup name cx of
                                                    Nothing -> Nothing
                                                    Just (_,_,Nothing) -> Nothing
                                                    Just (_,_,Just cx') -> resolver rest cx'
        in case msum . map (resolver nameIn) $ context of
             Nothing -> rerr errMsg
             Just x -> Just x
      processFDP fdp = fdp
        { D.FileDescriptorProto.message_type = fmap (processMSG protoContext) (D.FileDescriptorProto.message_type fdp)
        , D.FileDescriptorProto.enum_type    = fmap (processENM protoContext) (D.FileDescriptorProto.enum_type fdp)
        , D.FileDescriptorProto.service      = fmap (processSRV protoContext) (D.FileDescriptorProto.service fdp)
        , D.FileDescriptorProto.extension    = fmap (processFLD protoContext Nothing) (D.FileDescriptorProto.extension fdp) }
      processMSG cx msg = msg
        { D.DescriptorProto.name        = self
        , D.DescriptorProto.field       = fmap (processFLD cx' self) (D.DescriptorProto.field msg)
        , D.DescriptorProto.extension   = fmap (processFLD cx' self) (D.DescriptorProto.extension msg)
        , D.DescriptorProto.nested_type = fmap (processMSG cx') (D.DescriptorProto.nested_type msg)
        , D.DescriptorProto.enum_type   = fmap (processENM cx') (D.DescriptorProto.enum_type msg) }
       where cx' = descend cx (D.DescriptorProto.name msg)
             self = resolve cx (D.DescriptorProto.name msg)
      processFLD cx mp f = f { D.FieldDescriptorProto.name          = mangleFieldName (D.FieldDescriptorProto.name f)
                             , D.FieldDescriptorProto.type'         = new_type'
                             , D.FieldDescriptorProto.type_name     = if new_type' == Just TYPE_GROUP
                                                                        then groupName
                                                                        else fmap fst r2
                             , D.FieldDescriptorProto.default_value = checkEnumDefault
                             , D.FieldDescriptorProto.extendee      = fmap newExt (D.FieldDescriptorProto.extendee f)}
       where newExt :: Utf8 -> Utf8
             newExt orig = let e2 = resolveWithNameType cx orig
                           in case (e2,D.FieldDescriptorProto.number f) of
                                (Just (newName,Message ers),Just fid) ->
                                  if checkER ers fid then newName
                                    else rerr $ "*** Name resolution found an extension field that is out of the allowed extension ranges: "++show f ++ "\n has a number "++ show fid ++" not in one of the valid ranges: " ++ show ers
                                (Just _,_) -> rerr $ "*** Name resolution found wrong type for "++show orig++" : "++show e2
                                (Nothing,Just {}) -> rerr $ "*** Name resolution failed for the extendee: "++show f
                                (_,Nothing) -> rerr $ "*** No field id number for the extension field: "++show f
             r2 = fmap (fromMaybe (rerr $ "*** Name resolution failed for the type_name of extension field: "++show f)
                         . (resolveWithNameType cx))
                       (D.FieldDescriptorProto.type_name f)
             t (Message {}) = TYPE_MESSAGE
             t (Enumeration {}) = TYPE_ENUM
             t _ = rerr $ unlines [ "Problem found: processFLD cannot resolve type_name to Void or Service"
                                  , "  The parent message is "++maybe "<no message>" toString mp
                                  , "  The field name is "++maybe "<no field name>" toString (D.FieldDescriptorProto.name f)]
             new_type' = (D.FieldDescriptorProto.type' f) `mplus` (fmap (t.snd) r2)
             checkEnumDefault = case (D.FieldDescriptorProto.default_value f,fmap snd r2) of
                                  (Just name,Just (Enumeration values)) | name  `elem` values -> mangleEnum (Just name)
                                                                        | otherwise ->
                                      rerr $ unlines ["Problem found: default enumeration value not recognized:"
                                                     ,"  The parent message is "++maybe "<no message>" toString mp
                                                     ,"  field name is "++maybe "" toString (D.FieldDescriptorProto.name f)
                                                     ,"  bad enum name is "++show (toString name)
                                                     ,"  possible enum values are "++show (map toString values)]
                                  (Just def,_) | new_type' == Just TYPE_MESSAGE
                                                 || new_type' == Just TYPE_GROUP ->
                                    rerr $ "Problem found: You set a default value for a MESSAGE or GROUP: "++unlines [show def,show f]
                                  (maybeDef,_) -> maybeDef
  
             groupName = case mp of
                           Nothing -> resolve cx (D.FieldDescriptorProto.name f)
                           Just p -> do n <- D.FieldDescriptorProto.name f
                                        return (Utf8 . U.fromString . (toString p++) . ('.':) . mangleModuleName . toString $ n)

      processENM cx e = e { D.EnumDescriptorProto.name = resolve cx (D.EnumDescriptorProto.name e)
                          , D.EnumDescriptorProto.value = mangleEnums (D.EnumDescriptorProto.value e) }
      processSRV cx s = s { D.ServiceDescriptorProto.name   = resolve cx (D.ServiceDescriptorProto.name s)
                          , D.ServiceDescriptorProto.method = fmap (processMTD cx) (D.ServiceDescriptorProto.method s) }
      processMTD cx m = m { D.MethodDescriptorProto.name        = mangleFieldName (D.MethodDescriptorProto.name m)
                          , D.MethodDescriptorProto.input_type  = resolve cx (D.MethodDescriptorProto.input_type m)
                          , D.MethodDescriptorProto.output_type = resolve cx (D.MethodDescriptorProto.output_type m) }
  in processFDP protoIn