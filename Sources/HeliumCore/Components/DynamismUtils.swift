//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/28/24.
//

import Foundation
import SwiftyJSON

public func createDynamicComponentIfExists(for key: String, in templateValues: JSON) -> [DynamicPositionedComponent] {
    templateValues[key].map { DynamicPositionedComponent(json: $1) }
}

public func resolveReferences(_ json: JSON, templateValues: JSON) -> JSON {
    func resolve(_ element: JSON) -> JSON {
        if let ref = element["$ref"].string {
            return resolve(templateValues[ref])
        } else if element.type == .array {
            return JSON(element.arrayValue.map { resolve($0) })
        } else if element.type == .dictionary {
            var resolved = JSON([:])
            for (key, value) in element {
                resolved[key] = resolve(value)
            }
            return resolved
        } else {
            return element
        }
    }
    
    return resolve(json)
}
