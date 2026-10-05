import Foundation

/// JSON-Schema der PRL v1. Wird in Debug-Pakete als `schema/prl-v1.json` gelegt, damit ein
/// externer Agent valide Recipes erzeugen kann. Spiegel unter `docs/schema/prl-v1.json`.
public enum PRLSchema {
    public static let json: String = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://github.com/GodModeAI2025/AnyWiFiiOS/schema/prl-v1.json",
      "title": "Portal Recipe Language v1",
      "type": "object",
      "additionalProperties": false,
      "required": ["recipeVersion", "name", "network", "stages"],
      "properties": {
        "recipeVersion": {"const": 1},
        "profileId": {"type": "string"},
        "name": {"type": "string", "minLength": 1},
        "network": {
          "type": "object",
          "additionalProperties": false,
          "required": ["ssid"],
          "properties": {"ssid": {"type": "string", "minLength": 1}}
        },
        "stages": {
          "type": "array",
          "minItems": 1,
          "maxItems": 12,
          "items": {"$ref": "#/$defs/stage"}
        },
        "success": {
          "type": "object",
          "additionalProperties": false,
          "properties": {"internetAccess": {"type": "boolean"}}
        }
      },
      "$defs": {
        "stringList": {"type": "array", "items": {"type": "string"}},
        "stage": {
          "type": "object",
          "additionalProperties": false,
          "required": ["id", "actions"],
          "properties": {
            "id": {"type": "string", "minLength": 1},
            "match": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "anyText": {"$ref": "#/$defs/stringList"},
                "fields": {"$ref": "#/$defs/stringList"},
                "urlContains": {"$ref": "#/$defs/stringList"}
              }
            },
            "actions": {"type": "array", "minItems": 1, "maxItems": 20, "items": {"$ref": "#/$defs/action"}}
          }
        },
        "target": {
          "type": "object",
          "additionalProperties": false,
          "minProperties": 1,
          "properties": {
            "role": {"type": "string"},
            "concept": {"type": "string"},
            "labelAny": {"$ref": "#/$defs/stringList"},
            "nameAny": {"$ref": "#/$defs/stringList"},
            "placeholderAny": {"$ref": "#/$defs/stringList"},
            "ariaAny": {"$ref": "#/$defs/stringList"},
            "nearbyAny": {"$ref": "#/$defs/stringList"},
            "ordinal": {"type": "integer", "minimum": 0},
            "lastKnownSelector": {"type": "string"}
          }
        },
        "valueSource": {
          "type": "object",
          "minProperties": 1,
          "maxProperties": 1,
          "additionalProperties": false,
          "properties": {
            "literal": {"type": "string"},
            "profile": {"type": "string"},
            "keychain": {"type": "string"},
            "ask": {"type": "string"},
            "runtime": {"type": "string"}
          }
        },
        "action": {
          "oneOf": [
            {"const": "submit"},
            {"type": "object", "additionalProperties": false, "required": ["fill"], "properties": {"fill": {
              "type": "object", "additionalProperties": false, "required": ["target", "value"],
              "properties": {"target": {"$ref": "#/$defs/target"}, "value": {"$ref": "#/$defs/valueSource"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["check"], "properties": {"check": {
              "type": "object", "additionalProperties": false, "required": ["target"],
              "properties": {"target": {"$ref": "#/$defs/target"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["uncheck"], "properties": {"uncheck": {
              "type": "object", "additionalProperties": false, "required": ["target"],
              "properties": {"target": {"$ref": "#/$defs/target"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["select"], "properties": {"select": {
              "type": "object", "additionalProperties": false, "required": ["target", "option"],
              "properties": {"target": {"$ref": "#/$defs/target"}, "option": {"type": "string"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["tap"], "properties": {"tap": {
              "type": "object", "additionalProperties": false, "required": ["target"],
              "properties": {"target": {"$ref": "#/$defs/target"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["submit"], "properties": {"submit": {
              "type": "object", "additionalProperties": false}}},
            {"type": "object", "additionalProperties": false, "required": ["requestValue"], "properties": {"requestValue": {
              "type": "object", "additionalProperties": false, "required": ["concept"],
              "properties": {"concept": {"type": "string"}, "prompt": {"type": "string"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["waitFor"], "properties": {"waitFor": {
              "type": "object", "additionalProperties": false, "minProperties": 1, "maxProperties": 1,
              "properties": {"urlContains": {"type": "string"}, "textAny": {"$ref": "#/$defs/stringList"},
                             "elementConcept": {"type": "string"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["verify"], "properties": {"verify": {
              "type": "object", "additionalProperties": false, "minProperties": 1, "maxProperties": 1,
              "properties": {"internetAccess": {"type": "boolean"}, "pageContainsAny": {"$ref": "#/$defs/stringList"}}}}},
            {"type": "object", "additionalProperties": false, "required": ["stop"], "properties": {"stop": {
              "enum": ["success", "temporaryFailure", "unsupported", "requiresManualInteraction"]}}}
          ]
        }
      }
    }
    """#
}
