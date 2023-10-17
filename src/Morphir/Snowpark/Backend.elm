module Morphir.Snowpark.Backend exposing (..)

import Dict
import List
import Morphir.File.FileMap exposing (FileMap)
import Morphir.IR.AccessControlled exposing (Access(..), AccessControlled)
import Morphir.IR.Distribution as Distribution exposing (..)
import Morphir.IR.Name as Name
import Morphir.IR.Package as Package
import Morphir.IR.Module as Module 
import Morphir.IR.Path as Path exposing (Path)
import Morphir.IR.Type exposing (Type)
import Morphir.Scala.AST as Scala
import Morphir.Scala.PrettyPrinter as PrettyPrinter
import Morphir.TypeSpec.Backend exposing (mapModuleDefinition)
import Morphir.IR.Type  exposing (Type)
import Morphir.Scala.Common exposing (mapValueName)
import Morphir.IR.Value as Value exposing (Pattern(..), Value(..))
import Morphir.Snowpark.MappingContext as MappingContext
import Morphir.IR.FQName as FQName
import Morphir.IR.Literal exposing (Literal(..))
import Morphir.Snowpark.Constants as Constants
import Morphir.Snowpark.RecordWrapperGenerator as RecordWrapperGenerator
import Morphir.Snowpark.MappingContext exposing (MappingContextInfo)


type alias Options =
    {}

mapDistribution : Options -> Distribution -> FileMap
mapDistribution _ distro =
    case distro of
        Distribution.Library packageName _ packageDef ->
            mapPackageDefinition distro packageName packageDef


mapPackageDefinition : Distribution -> Package.PackageName -> Package.Definition ta (Type ()) -> FileMap
mapPackageDefinition _ packagePath packageDef =
    let
        contextInfo = MappingContext.processDistributionModules packagePath packageDef
        -- TODO: remove the following defintion
        tmp = Debug.log (String.join "\n" (contextInfo |> Dict.toList |> List.map (\(n,v) -> (FQName.toString n) ++ ", " ++ (Debug.toString v))) ) 1
        generatedScala =
            packageDef.modules
                |> Dict.toList
                |> List.concatMap
                    (\( modulePath, moduleImpl ) ->
                        mapModuleDefinition packagePath modulePath moduleImpl contextInfo
                    )
    in
    generatedScala
        |> List.map
            (\compilationUnit ->
                let
                    fileContent =
                        compilationUnit
                            |> PrettyPrinter.mapCompilationUnit (PrettyPrinter.Options 2 80)
                in
                ( ( compilationUnit.dirPath, compilationUnit.fileName ), fileContent )
            )
        |> Dict.fromList


mapModuleDefinition : Package.PackageName -> Path -> AccessControlled (Module.Definition ta (Type ())) -> MappingContextInfo a -> List Scala.CompilationUnit
mapModuleDefinition currentPackagePath currentModulePath accessControlledModuleDef mappingCtx =
    let
        ( scalaPackagePath, moduleName ) =
            case currentModulePath |> List.reverse of
                [] ->
                    ( [], [] )

                lastName :: reverseModulePath ->
                    let
                        parts =
                            List.append currentPackagePath (List.reverse reverseModulePath)
                    in
                    ( parts |> (List.concat >> List.map String.toLower), lastName )

        classDefinitions : List (Scala.Documented (Scala.Annotated Scala.TypeDecl))
        classDefinitions = 
            accessControlledModuleDef.value.types
                |> RecordWrapperGenerator.generateRecordWrappers currentPackagePath currentModulePath mappingCtx

        functionMembers : List (Scala.Annotated Scala.MemberDecl)
        functionMembers =
            accessControlledModuleDef.value.values
                |> Dict.toList
                |> List.concatMap
                    (\( valueName, accessControlledValueDef ) ->
                        [ Scala.FunctionDecl
                            { modifiers = []
                            , name = mapValueName valueName
                            , typeArgs = []                                
                            , args = []                                
                            , returnType = Nothing
                            , body =
                                mapFunctionBody accessControlledValueDef.value.value
                            }
                        ]
                    )
                |> List.map Scala.withoutAnnotation
        moduleUnit : Scala.CompilationUnit
        moduleUnit =
            { dirPath = scalaPackagePath
            , fileName = (moduleName |> Name.toTitleCase) ++ ".scala"
            , packageDecl = scalaPackagePath
            , imports = []
            , typeDecls = (( Scala.Documented (Just (String.join "" [ "Generated based on ", currentModulePath |> Path.toString Name.toTitleCase "." ]))
                    (Scala.Annotated []
                        (Scala.Object
                            { modifiers =
                                case accessControlledModuleDef.access of
                                    Public ->
                                        []

                                    Private ->
                                        []
                            , name =
                                moduleName |> Name.toTitleCase
                            , members = 
                                List.append [] functionMembers
                            , extends =
                                []
                            , body = Nothing
                            }
                        )
                    )
                ) :: classDefinitions)
            }
    in
    [ moduleUnit ]


mapFunctionBody : Value.Definition ta (Type ()) -> Maybe Scala.Value
mapFunctionBody value =
           Maybe.Just (mapValue value.body)

mapValue : Value ta (Type ()) -> Scala.Value
mapValue value =
    case value of
        Literal tpe literal ->
            mapLiteral tpe literal
        _ ->
            Scala.Literal (Scala.StringLit "To Do")

mapLiteral : ta -> Literal -> Scala.Value
mapLiteral tpe literal =
    case literal of
                CharLiteral val ->
                    Constants.applySnowparkFunc "lit" [(Scala.Literal (Scala.CharacterLit val))]
                StringLiteral val ->                    
                    Constants.applySnowparkFunc "lit" [(Scala.Literal (Scala.StringLit val))]
                BoolLiteral val ->
                    Constants.applySnowparkFunc "lit" [(Scala.Literal (Scala.BooleanLit val))]
                WholeNumberLiteral val ->
                    Constants.applySnowparkFunc "lit" [(Scala.Literal (Scala.IntegerLit val))]
                FloatLiteral val ->
                    Constants.applySnowparkFunc "lit" [(Scala.Literal (Scala.FloatLit val))]
                _ ->
                    Debug.todo "The type '_' is not implemented"