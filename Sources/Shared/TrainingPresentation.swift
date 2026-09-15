import Foundation

/// Formats confirmed training records; it never derives a schedule from templates.
struct TrainingPresentation {
    let language: AppLanguage
    var now: Date = Date()
    var timeZone: TimeZone = .current

    func text(_ key: String) -> String {
        let copy: [String: (String, String)] = [
            "title": ("Тренировки", "Training"),
            "last": ("Последняя завершённая", "Last completed"),
            "next": ("Ближайшая по плану", "Next planned"),
            "completed": ("Выполнена", "Completed"),
            "planned": ("По плану", "Scheduled"),
            "recent": ("Последние занятия", "Recent activities"),
            "upcoming": ("Расписание", "Upcoming workouts"),
            "workout": ("Тренировка", "Workout"),
            "dateUnknown": ("Дата не указана", "Date not provided"),
            "timeUnknown": ("Время не указано", "Time not provided"),
            "localTime": ("местное время записи", "recorded local time"),
            "durationUnknown": ("Длительность не указана", "Duration not provided"),
            "pastUnavailable": ("История пока недоступна", "History is not available yet"),
            "pastUnavailableHint": ("Для этого раздела ещё нет подтверждённой загрузки Garmin.", "This section has not been successfully retrieved from Garmin yet."),
            "pastEmpty": ("В последней выборке нет занятий", "No activities in the latest response"),
            "pastCoverage": ("До 20 последних занятий · не вся история", "Up to 20 recent activities · not the full history"),
            "futureUnavailable": ("Расписание пока недоступно", "Schedule is not available yet"),
            "futureUnavailableHint": ("Недоступный календарь не означает, что тренировок нет.", "An unavailable calendar does not mean there are no workouts."),
            "futureEmpty": ("В загруженной части нет тренировок", "No workouts in the retrieved portion"),
            "calendar": ("Опубликованный календарь Garmin", "Published Garmin calendar"),
            "adaptive": ("Проверенный адаптивный календарь", "Verified adaptive calendar"),
            "partial": ("Часть календаря недоступна", "Part of the calendar is unavailable"),
            "expiredCoverage": ("Проверенный период закончился", "The checked period has ended"),
            "refreshCalendar": ("Обновите данные, чтобы увидеть новый период.", "Refresh to check a new period."),
            "updated": ("Обновлено", "Updated"),
            "updatedUnknown": ("Время обновления неизвестно", "Update time is unknown"),
            "cached": ("Сохранённые данные", "Saved data"),
            "refreshFailed": ("Не удалось обновить раздел", "This section could not be refreshed"),
            "rateLimit": ("Garmin временно ограничил запросы", "Garmin is temporarily limiting requests"),
            "signIn": ("Для обновления войдите в Garmin Connect", "Sign in to Garmin Connect to refresh"),
            "hour": ("ч", "h"), "minute": ("мин", "min"), "second": ("с", "s"), "km": ("км", "km")
        ]
        guard let value = copy[key] else { return key }
        return language.effectiveCode == "ru" ? value.0 : value.1
    }

    private func sport(_ key: String) -> (String, String, String) {
        switch key.lowercased() {
        case "running", "run": return ("Бег", "Running", "figure.run")
        case "trail_running": return ("Трейл", "Trail running", "figure.run")
        case "treadmill_running", "indoor_running": return ("Беговая дорожка", "Treadmill running", "figure.run")
        case "track_running": return ("Бег на стадионе", "Track running", "figure.run")
        case "cycling", "biking", "road_biking": return ("Велосипед", "Cycling", "figure.outdoor.cycle")
        case "mountain_biking", "gravel_cycling": return ("Велосипед по бездорожью", "Off-road cycling", "figure.outdoor.cycle")
        case "indoor_cycling", "virtual_ride": return ("Велотренировка в помещении", "Indoor cycling", "figure.indoor.cycle")
        case "swimming", "lap_swimming", "pool_swim": return ("Плавание", "Swimming", "figure.pool.swim")
        case "open_water_swimming": return ("Открытая вода", "Open-water swimming", "figure.open.water.swim")
        case "walking", "casual_walking", "speed_walking": return ("Ходьба", "Walking", "figure.walk")
        case "hiking", "mountaineering": return ("Поход", "Hiking", "figure.hiking")
        case "strength_training", "strength": return ("Силовая тренировка", "Strength training", "dumbbell.fill")
        case "cardio_training", "indoor_cardio", "fitness_equipment", "hiit": return ("Кардио", "Cardio", "heart.fill")
        case "elliptical": return ("Эллипс", "Elliptical", "figure.elliptical")
        case "stair_climbing": return ("Подъём по лестнице", "Stair climbing", "figure.stairs")
        case "yoga": return ("Йога", "Yoga", "figure.yoga")
        case "pilates": return ("Пилатес", "Pilates", "figure.pilates")
        case "rowing", "indoor_rowing": return ("Гребля", "Rowing", "figure.rower")
        case "tennis": return ("Теннис", "Tennis", "figure.tennis")
        case "golf": return ("Гольф", "Golf", "figure.golf")
        case "alpine_skiing", "resort_skiing": return ("Горные лыжи", "Alpine skiing", "figure.skiing.downhill")
        case "cross_country_skiing": return ("Беговые лыжи", "Cross-country skiing", "figure.skiing.crosscountry")
        case "snowboarding": return ("Сноуборд", "Snowboarding", "figure.snowboarding")
        case "triathlon", "multisport": return ("Мультиспорт", "Multisport", "figure.run")
        default: return (text("workout"), text("workout"), "figure.mixed.cardio")
        }
    }

    func sportTitle(_ key: String) -> String { let value = sport(key); return language.effectiveCode == "ru" ? value.0 : value.1 }
    func sportSymbol(_ key: String) -> String { sport(key).2 }
    func title(for activity: PastActivitySummary) -> String { nonempty(activity.title) ?? sportTitle(activity.sportKey) }
    func title(for workout: PlannedWorkoutSummary) -> String { nonempty(workout.title) ?? sportTitle(workout.sportKey) }

    func duration(_ minutes: Double?) -> String? {
        guard let minutes, minutes.isFinite, minutes >= 0 else { return nil }
        let seconds = (minutes * 60).rounded()
        guard seconds.isFinite, seconds < Double(Int.max) else { return nil }
        if minutes > 0 && seconds < 1 { return "< 1 " + text("second") }
        let total = Int(seconds), hours = total / 3_600, remainingMinutes = (total % 3_600) / 60, remainingSeconds = total % 60
        if total == 0 { return "0 " + text("minute") }
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) " + text("hour")) }
        if remainingMinutes > 0 { parts.append("\(remainingMinutes) " + text("minute")) }
        if remainingSeconds > 0 { parts.append("\(remainingSeconds) " + text("second")) }
        return parts.joined(separator: " ")
    }

    func distance(_ kilometers: Double?) -> String? {
        guard let kilometers, kilometers.isFinite, kilometers >= 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = language.locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2
        guard let number = formatter.string(from: NSNumber(value: kilometers)) else { return nil }
        return number + " " + text("km")
    }

    func dateText(for activity: PastActivitySummary) -> String {
        if let instant = activity.startedAt { return dateTime(instant) }
        if let local = activity.localStart, let value = parseLocal(local) {
            return dateTime(value, zone: TimeZone(secondsFromGMT: 0)!) + " · " + text("localTime")
        }
        return text("dateUnknown")
    }

    func dateText(for workout: PlannedWorkoutSummary) -> String {
        if let instant = workout.startsAt { return dateTime(instant) }
        guard let day = dayText(workout.localDate) else { return text("dateUnknown") }
        return day + " · " + text("timeUnknown")
    }

    func dayText(_ day: String) -> String? {
        guard let date = parseDay(day) else { return nil }
        let formatter = dateFormatter(zone: TimeZone(secondsFromGMT: 0)!)
        formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    func recentActivities(in snapshot: TrainingTimelineSnapshot?) -> [PastActivitySummary] {
        Array((snapshot?.past ?? []).sorted {
            if let left = $0.startedAt, let right = $1.startedAt, left != right { return left > right }
            if ($0.startedAt == nil) != ($1.startedAt == nil) { return $0.startedAt != nil }
            if $0.localStart != $1.localStart { return ($0.localStart ?? "") > ($1.localStart ?? "") }
            return $0.id < $1.id
        }.prefix(20))
    }

    func upcomingWorkouts(in snapshot: TrainingTimelineSnapshot?) -> [PlannedWorkoutSummary] {
        (snapshot?.upcoming ?? []).filter {
            if let instant = $0.startsAt { return instant >= now }
            return parseDay($0.localDate) != nil && $0.localDate >= today
        }.sorted {
            if $0.localDate != $1.localDate { return $0.localDate < $1.localDate }
            if let left = $0.startsAt, let right = $1.startsAt, left != right { return left < right }
            if ($0.startsAt == nil) != ($1.startsAt == nil) { return $0.startsAt == nil }
            return $0.id < $1.id
        }
    }

    func pastAvailable(_ snapshot: TrainingTimelineSnapshot?) -> Bool {
        snapshot?.pastCoverage == .recentActivities && snapshot?.pastUpdatedAt != nil
    }

    func futureAvailable(_ snapshot: TrainingTimelineSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.futureCoverage != .unavailable && snapshot.futureUpdatedAt != nil
    }

    func pastEmptyText(_ snapshot: TrainingTimelineSnapshot?) -> String { text(pastAvailable(snapshot) ? "pastEmpty" : "pastUnavailable") }

    func futureEmptyText(_ snapshot: TrainingTimelineSnapshot?) -> String {
        guard futureAvailable(snapshot) else { return text("futureUnavailable") }
        if let end = snapshot?.futureCoverageEnd, parseDay(end) != nil {
            if end < today { return text("expiredCoverage") }
            if let date = dayText(end) {
                return language.effectiveCode == "ru" ? "Нет опубликованных тренировок по \(date)" : "No published workouts through \(date)"
            }
        }
        return text("futureEmpty")
    }

    func futureCoverageText(_ snapshot: TrainingTimelineSnapshot?) -> String {
        guard futureAvailable(snapshot) else { return text("futureUnavailableHint") }
        let base = text(snapshot?.futureCoverage == .adaptiveVerified ? "adaptive" : "calendar")
        if let end = snapshot?.futureCoverageEnd, let date = dayText(end) {
            return base + " · " + (language.effectiveCode == "ru" ? "проверено по \(date)" : "checked through \(date)")
        }
        return base + " · " + text("partial")
    }

    func freshness(_ date: Date?) -> String {
        guard let date else { return text("updatedUnknown") }
        return text("updated") + " " + dateTime(date)
    }

    func issueText(_ issue: String?, cached: Bool) -> String? {
        guard let issue else { return nil }
        let message: String
        switch issue {
        case "partial_calendar": message = text("partial")
        case "rate_limit": message = text("rateLimit")
        case "auth", "session_expired", "sign_in_required": message = text("signIn")
        default: message = text("refreshFailed")
        }
        return cached ? message + " · " + text("cached") : message
    }

    private var today: String {
        let formatter = dateFormatter(zone: timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private func dateTime(_ date: Date, zone: TimeZone? = nil) -> String {
        let formatter = dateFormatter(zone: zone ?? timeZone)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func dateFormatter(zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale; formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = zone
        return formatter
    }

    private func parseDay(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        return parse(value, format: "yyyy-MM-dd")
    }

    private func parseLocal(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        return parse(value, format: "yyyy-MM-dd'T'HH:mm:ss")
    }

    private func parse(_ value: String, format: String) -> Date? {
        let parser = dateFormatter(zone: TimeZone(secondsFromGMT: 0)!)
        parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = format; parser.isLenient = false
        guard let date = parser.date(from: value), parser.string(from: date) == value else { return nil }
        return date
    }

    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
