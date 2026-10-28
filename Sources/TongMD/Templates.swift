import Foundation

enum Templates {
    static let defaultDaily = """
    # {{date}}

    ## 速记

    ## 记录
    """

    static func render(_ template: String, title: String, date: Date = Date()) -> String {
        let day = DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        _ = day

        return template
            .replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{{title}}", with: title)
    }

    static func dailyName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
