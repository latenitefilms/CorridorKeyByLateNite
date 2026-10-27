import Foundation

/// Foundation-only values shared by custom inspector rows and the published storage channel.
enum CustomParameterValue {
    /// Matches the empty dictionary archived in the Motion template.
    static var empty: NSDictionary { NSDictionary() }

    /// Every class that can occur in hints, asset bookmarks and analysis metadata.
    static var allowedClasses: [AnyClass] {
        [NSDictionary.self, NSMutableDictionary.self, NSString.self,
         NSNumber.self, NSData.self, NSMutableData.self]
    }

    /// Objective-C's NSSet<Class> contract shared by the effect and its separate OSC session.
    static var allowedClassSet: Set<AnyHashable> {
        (NSSet(array: allowedClasses) as? Set<AnyHashable>) ?? []
    }
}
