import 'dart:async';
import 'dart:mirrors';

import 'package:aqueduct/aqueduct.dart';
import 'package:aqueduct/src/http/resource_controller_bindings.dart';
import 'package:aqueduct/src/http/resource_controller_interfaces.dart';
import 'package:aqueduct/src/runtime/resource_controller/documenter.dart';
import 'package:aqueduct/src/runtime/resource_controller/utility.dart';
import 'package:aqueduct/src/runtime/resource_controller_generator.dart';
import 'package:aqueduct/src/utilities/mirror_cast.dart';
import 'package:aqueduct/src/utilities/mirror_helpers.dart';
import 'package:meta/meta.dart';
import 'package:runtime/runtime.dart' hide firstMetadataOfType;

class ResourceControllerRuntimeImpl extends ResourceControllerRuntime {
  ResourceControllerRuntimeImpl(this.type) {
    final allDeclarations = type.declarations;

    ivarParameters = allDeclarations.values
        .whereType<VariableMirror>()
        .where((decl) => decl.metadata.any((im) => im.reflectee is Bind))
        .map((decl) {
      final isRequired = allDeclarations[decl.simpleName]
          .metadata
          .any((im) => im.reflectee is RequiredBinding);
      return getParameterForVariable(decl, isRequired: isRequired);
    }).toList();

    operations = type.instanceMembers.values
        .where(isOperation)
        .map(getOperationForMethod)
        .toList();

    if (conflictingOperations.isNotEmpty) {
      final opNames = conflictingOperations.map((s) => "'$s'").join(", ");
      throw StateError(
          "Invalid controller. Controller '${type.reflectedType.toString()}' has "
          "ambiguous operations. Offending operating methods: $opNames.");
    }

    if (unsatisfiableOperations.isNotEmpty) {
      final opNames = unsatisfiableOperations.map((s) => "'$s'").join(", ");
      throw StateError(
          "Invalid controller. Controller '${type.reflectedType.toString()}' has operations where "
          "parameter is bound with @Bind.path(), but path variable is not declared in "
          "@Operation(). Offending operation methods: $opNames");
    }

    documenter = ResourceControllerDocumenterImpl(this);
  }

  final ClassMirror type;

  String compile(BuildContext ctx) =>
      getResourceControllerImplSource(this, ctx);

  List<String> get unsatisfiableOperations {
    return operations
        .where((op) {
          final argPathParameters = op.positionalParameters
              .where((p) => p.location == BindingType.path);

          return !argPathParameters
              .every((p) => op.pathVariables.contains(p.name));
        })
        .map((op) => op.dartMethodName)
        .toList();
  }

  List<String> get conflictingOperations {
    return operations
        .where((op) {
          final possibleConflicts = operations.where((b) => b != op);

          return possibleConflicts.any((opToCompare) {
            if (opToCompare.httpMethod != op.httpMethod) {
              return false;
            }

            if (opToCompare.pathVariables.length != op.pathVariables.length) {
              return false;
            }

            return opToCompare.pathVariables
                .every((p) => op.pathVariables.contains(p));
          });
        })
        .map((op) => op.dartMethodName)
        .toList();
  }

  @override
  void applyRequestProperties(ResourceController untypedController,
      ResourceControllerOperationInvocationArgs args) {
    final rcMirror = reflect(untypedController);

    args.instanceVariables.forEach(rcMirror.setField);
  }

  ResourceControllerParameter getParameterForVariable(VariableMirror mirror,
      {@required bool isRequired}) {
    final metadata = mirror.metadata
        .firstWhere((im) => im.reflectee is Bind)
        .reflectee as Bind;

    if (mirror.type is! ClassMirror) {
      throw _makeError(mirror, "Cannot bind dynamic parameters.");
    }

    final boundType = mirror.type as ClassMirror;
    dynamic Function(dynamic input) decoder;

    switch (metadata.bindingType) {
      case BindingType.body:
        {
          final isDecodingSerializable =
              isSerializable(boundType.reflectedType);
          final isDecodingListOfSerializable =
              isListSerializable(boundType.reflectedType);
          if (metadata.ignore != null ||
              metadata.reject != null ||
              metadata.require != null) {
            if (!(isDecodingSerializable || isDecodingListOfSerializable)) {
              throw _makeError(mirror,
                  "Filters can only be used on Serializable or List<Serializable>.");
            }
          }
          decoder = (b) {
            final body = b as RequestBody;
            if (body.isEmpty) {
              return null;
            }

            if (isDecodingSerializable) {
              final value = boundType
                  .newInstance(const Symbol(""), []).reflectee as Serializable;
              value.read(body.as(),
                  ignore: metadata.ignore,
                  reject: metadata.reject,
                  require: metadata.require);

              return value;
            } else if (isDecodingListOfSerializable) {
              final bodyList = body.as<List<Map<String, dynamic>>>();
              if (bodyList.isEmpty) {
                return boundType.newInstance(#from, [[]]).reflectee;
              }

              final typeArg = boundType.typeArguments.first as ClassMirror;
              final iterable = bodyList.map((object) {
                final value =
                    typeArg.newInstance(const Symbol(""), []).reflectee
                        as Serializable;
                value.read(object,
                    ignore: metadata.ignore,
                    reject: metadata.reject,
                    require: metadata.require);

                return value;
              }).toList();

              final v = boundType.newInstance(#from, [iterable]).reflectee;
              return v;
            }

            return runtimeCast(body.as(), boundType);
          };
        }
        break;
      case BindingType.query:
        {
          final isListOfBools = boundType.isAssignableTo(reflectType(List)) &&
              boundType.typeArguments.first.isAssignableTo(reflectType(bool));

          if (!(boundType.isAssignableTo(reflectType(bool)) || isListOfBools)) {
            if (boundType.isAssignableTo(reflectType(List))) {
              _enforceTypeCanBeParsedFromString(
                  mirror, boundType.typeArguments.first);
            } else {
              _enforceTypeCanBeParsedFromString(mirror, boundType);
            }
          }
          decoder = (value) {
            return _convertParameterListWithMirror(
                value as List<String>, boundType);
          };
        }
        break;
      case BindingType.path:
        {
          decoder = (value) {
            return _convertParameterWithMirror(value as String, mirror.type);
          };
        }
        break;
      case BindingType.header:
        {
          if (boundType.isAssignableTo(reflectType(List))) {
            _enforceTypeCanBeParsedFromString(
                mirror, boundType.typeArguments.first);
          } else {
            _enforceTypeCanBeParsedFromString(mirror, boundType);
          }
          decoder = (value) {
            return _convertParameterListWithMirror(
                value as List<String>, mirror.type);
          };
        }
        break;
    }

    return ResourceControllerParameter(
        name: metadata.name,
        type: mirror.type.reflectedType,
        symbolName: MirrorSystem.getName(mirror.simpleName),
        location: metadata.bindingType,
        isRequired: isRequired,
        decoder: decoder);
  }

  ResourceControllerOperation getOperationForMethod(MethodMirror mirror) {
    final operation = getMethodOperationMetadata(mirror);
    final symbol = mirror.simpleName;

    final parametersWithoutMetadata = mirror.parameters
        .where((p) => firstMetadataOfType<Bind>(p) == null)
        .toList();
    if (parametersWithoutMetadata.isNotEmpty) {
      final names = parametersWithoutMetadata
          .map((p) => "'${MirrorSystem.getName(p.simpleName)}'")
          .join(", ");
      throw StateError("Invalid operation method parameter(s) $names on "
          "'${getMethodAndClassName(parametersWithoutMetadata.first)}': Must have @Bind annotation.");
    }

    return ResourceControllerOperation(
        positionalParameters: mirror.parameters
            .where((pm) => !pm.isOptional)
            .map((pm) => getParameterForVariable(pm, isRequired: true))
            .toList(),
        namedParameters: mirror.parameters
            .where((pm) => pm.isOptional)
            .map((pm) => getParameterForVariable(pm, isRequired: false))
            .toList(),
        scopes: getMethodScopes(mirror),
        dartMethodName: MirrorSystem.getName(symbol),
        httpMethod: operation.method.toUpperCase(),
        pathVariables: operation.pathVariables,
        invoker: (rc, args) {
          return reflect(rc)
              .invoke(symbol, args.positionalArguments, args.namedArguments)
              .reflectee as Future<Response>;
        });
  }
}

StateError _makeError(VariableMirror mirror, String s) {
  return StateError(
      "Invalid binding '${MirrorSystem.getName(mirror.simpleName)}' "
      "on '${getMethodAndClassName(mirror)}': $s");
}

void _enforceTypeCanBeParsedFromString(
    VariableMirror varMirror, TypeMirror typeMirror) {
  if (typeMirror is! ClassMirror) {
    throw _makeError(varMirror, 'Cannot bind dynamic type parameters.');
  }

  if (typeMirror.isAssignableTo(reflectType(String))) {
    return;
  }

  final classMirror = typeMirror as ClassMirror;
  if (!classMirror.staticMembers.containsKey(#parse)) {
    throw _makeError(
        varMirror, 'Parameter type does not implement static parse method.');
  }

  final parseMethod = classMirror.staticMembers[#parse];
  final params = parseMethod.parameters.where((p) => !p.isOptional).toList();
  if (params.length == 1 &&
      params.first.type.isAssignableTo(reflectType(String))) {
    return;
  }

  throw _makeError(varMirror, 'Invalid parameter type.');
}

dynamic _convertParameterListWithMirror(
    List<String> parameterValues, TypeMirror typeMirror) {
  if (parameterValues == null) {
    return null;
  }

  if (typeMirror.isSubtypeOf(reflectType(List))) {
    final iterable = parameterValues.map((str) =>
        _convertParameterWithMirror(str, typeMirror.typeArguments.first));

    return (typeMirror as ClassMirror).newInstance(#from, [iterable]).reflectee;
  } else {
    if (parameterValues.length > 1) {
      throw ArgumentError("multiple values not expected");
    }
    return _convertParameterWithMirror(parameterValues.first, typeMirror);
  }
}

dynamic _convertParameterWithMirror(
    String parameterValue, TypeMirror typeMirror) {
  if (parameterValue == null) {
    return null;
  }

  if (typeMirror.isSubtypeOf(reflectType(bool))) {
    return true;
  }

  if (typeMirror.isSubtypeOf(reflectType(String))) {
    return parameterValue;
  }

  final classMirror = typeMirror as ClassMirror;
  final parseDecl = classMirror.declarations[#parse];
  try {
    return classMirror.invoke(parseDecl.simpleName, [parameterValue]).reflectee;
  } catch (_) {
    throw ArgumentError("invalid value");
  }
}
