/// The tabs after launch: the files saved last time, in their saved order, then any files given
/// at launch that are not already among them. A file in both lists keeps its saved place, once.
func mergeTabs<T>(saved: [T], launched: [T], key: (T) -> String) -> [T] {
    var seen = Set<String>()
    return (saved + launched).filter { seen.insert(key($0)).inserted }
}
