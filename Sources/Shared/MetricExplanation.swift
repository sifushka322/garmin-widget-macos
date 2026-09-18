import Foundation

/// Context supplied by Garmin for the same records as the snapshot. Missing
/// personal ranges stay missing; a raw number is never a fitness diagnosis.
struct GarminMetricContext: Codable, Equatable {
    var trainingLoadLower: Double? = nil
    var trainingLoadUpper: Double? = nil
    var trainingStatus: String? = nil
    var hrvStatus: String? = nil
    var hrvWeeklyAverage: Double? = nil
    var hrvBaselineLow: Double? = nil
    var hrvBaselineHigh: Double? = nil
    /// Garmin's acute-to-chronic ratio label is distinct from an acute-load range.
    var trainingLoadStatus: String? = nil
    var trainingLoadRatio: Double? = nil
}

struct MetricExplanation: Equatable {
    /// A short interpretation suitable for a widget or a metric card.
    var status: String
    /// Personal range, or a separate Garmin training status, when supplied.
    var supportingText: String? = nil
    var detail: String
    var sourceURL: URL? = nil

    static func helpLabel(language: AppLanguage) -> String {
        language.effectiveLanguage == .ru ? "Что означает показатель" : "What this means"
    }

    static func sourceLabel(language: AppLanguage) -> String {
        language.effectiveLanguage == .ru ? "Подробнее у Garmin" : "Learn more from Garmin"
    }

    static func make(metricID id: String, snapshot: GarminSnapshot, language: AppLanguage,
                     now: Date = Date()) -> MetricExplanation? {
        guard let value = MetricFormatter(snapshot: snapshot, language: language, now: now).value(id) else { return nil }
        let ru = language.effectiveLanguage == .ru
        func copy(_ en: String, _ russian: String) -> String { ru ? russian : en }
        func explanation(_ status: String, _ detail: String, supporting: String? = nil, source: String? = nil) -> MetricExplanation {
            MetricExplanation(status: status, supportingText: supporting, detail: detail, sourceURL: source.flatMap(URL.init(string:)))
        }
        func digits(_ number: Double) -> String {
            let formatter = NumberFormatter()
            formatter.locale = language.locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: number)) ?? "—"
        }
        let context = snapshot.retainedMetrics[id] == nil ? snapshot.metricContext : nil
        // These Garmin scales are displayed as whole points, including a
        // projected Body Battery value. Keep the label on the displayed band.
        let score = value.rounded(.toNearestOrAwayFromZero)
        switch id {
        case "trainingLoad":
            let loadSource = "https://www.garmin.com/en-GB/garmin-technology/cycling-science/physiological-measurements/training-load/"
            var status = copy("Personal range unavailable", "Нет личного диапазона")
            var lines: [String] = []
            switch context?.trainingLoadStatus {
            case "LOW": status = copy("Low load ratio", "Низкое соотношение нагрузок")
            case "OPTIMAL": status = copy("Optimal load ratio", "Оптимальное соотношение нагрузок")
            case "HIGH": status = copy("High load ratio", "Высокое соотношение нагрузок")
            case "VERY_HIGH": status = copy("Very high load ratio", "Очень высокое соотношение нагрузок")
            default: break
            }
            if let ratio = context?.trainingLoadRatio, ratio.isFinite, ratio >= 0 {
                let formatter = NumberFormatter()
                formatter.locale = language.locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2
                if let value = formatter.string(from: NSNumber(value: ratio)) {
                    lines.append(copy("Acute / chronic: ", "Острая / хроническая: ") + value)
                }
            }
            if let low = context?.trainingLoadLower, let high = context?.trainingLoadUpper,
               low.isFinite, high.isFinite, low >= 0, high > low {
                status = value < low ? copy("Below optimal range", "Ниже оптимального диапазона")
                    : value > high ? copy("Above optimal range", "Выше оптимального диапазона")
                    : copy("In optimal range", "В оптимальном диапазоне")
                lines.append(copy("Your range: ", "Ваш диапазон: ") + digits(low) + "–" + digits(high))
            }
            var detail = copy(
                "Acute load estimates the recent training strain on your body. Garmin weights recent sessions more heavily and compares the result with a range based on your fitness and training history. The number alone cannot show whether your training is productive.",
                "Острая нагрузка оценивает воздействие недавних тренировок на организм. Garmin придаёт больший вес свежим занятиям и сравнивает результат с диапазоном, рассчитанным по вашей форме и истории тренировок. Само число не показывает, насколько продуктивны тренировки.")
            if context?.trainingLoadRatio != nil || context?.trainingLoadStatus != nil {
                detail += "\n\n" + copy(
                    "The load ratio compares recent acute load with longer-term chronic load. Garmin supplies its category separately from training status.",
                    "Соотношение сравнивает недавнюю острую нагрузку с долгосрочной хронической. Garmin передаёт его категорию отдельно от тренировочного статуса.")
            }
            if let training = trainingStatus(context?.trainingStatus, language: language) {
                lines.append(copy("Garmin status: ", "Статус Garmin: ") + training.title)
                detail += "\n\n" + training.title + ": " + training.detail
            } else {
                detail += "\n\n" + copy(
                    "Training status also considers fitness trends and recovery. Low load by itself does not mean detraining. Garmin has not supplied a recognized training status for this reading.",
                    "Тренировочный статус учитывает также динамику формы и восстановление. Низкая нагрузка сама по себе не означает детренированность. Для этого значения Garmin не передал распознанный тренировочный статус.")
            }
            return explanation(status, detail, supporting: lines.isEmpty ? nil : lines.joined(separator: "\n"), source: loadSource)
        case "hrv":
            var status = copy("Compare with your baseline", "Сравнивайте со своей нормой")
            switch context?.hrvStatus?.uppercased().replacingOccurrences(of: "-", with: "_") {
            case "BALANCED": status = copy("Balanced weekly HRV", "HRV за неделю в балансе")
            case "UNBALANCED": status = copy("Unbalanced weekly HRV", "HRV за неделю вне баланса")
            case "LOW": status = copy("Low weekly HRV", "Низкая HRV за неделю")
            case "POOR": status = copy("Poor HRV status", "Низкий статус HRV")
            case "NONE", "NO_STATUS": status = copy("Insufficient recent HRV data", "Недостаточно свежих данных HRV")
            default: break
            }
            var lines: [String] = []
            if let weekly = context?.hrvWeeklyAverage, weekly.isFinite, weekly > 0 {
                lines.append(copy("7-day average: ", "Среднее за 7 дней: ") + digits(weekly) + copy(" ms", " мс"))
            }
            if let low = context?.hrvBaselineLow, let high = context?.hrvBaselineHigh,
               low.isFinite, high.isFinite, low > 0, high > low {
                lines.append(copy("Your baseline: ", "Ваша норма: ") + digits(low) + "–" + digits(high) + copy(" ms", " мс"))
            }
            return explanation(status, copy(
                "The displayed value is last night's average variation between heartbeats. Garmin's HRV status evaluates the 7-day average against your personal baseline, which takes about three weeks of sleep data to establish. One night's value is not the weekly status; higher is not always better.",
                "Число на карточке — средняя вариабельность интервалов между ударами сердца за последнюю ночь. Статус HRV Garmin сравнивает среднее за 7 дней с вашей личной нормой, для которой нужно около трёх недель данных сна. Значение за ночь и недельный статус — разные показатели; больше не всегда лучше."),
                supporting: lines.isEmpty ? nil : lines.joined(separator: "\n"),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-25E3235D-44D2-4384-A591-DD1D71BEBCB1/EN-US/GUID-9282196F-D969-404D-B678-F48A13D8D0CB.html")
        case "trainingReadiness":
            guard value >= 1, value <= 100 else { return nil }
            let status = score >= 95 ? copy("Prime readiness", "Отличная готовность")
                : score >= 75 ? copy("High readiness", "Высокая готовность")
                : score >= 50 ? copy("Moderate readiness", "Умеренная готовность")
                : score >= 25 ? copy("Low readiness", "Низкая готовность")
                : copy("Poor readiness", "Очень низкая готовность")
            return explanation(status, copy(
                "Garmin combines sleep, recovery time, HRV, acute load and recent stress. Scale: 1–24 poor, 25–49 low, 50–74 moderate, 75–94 high, 95–100 prime. Lower scores suggest prioritizing recovery; a high score indicates more capacity for a demanding session.",
                "Garmin объединяет данные сна, времени восстановления, HRV, острой нагрузки и недавнего стресса. Шкала: 1–24 — очень низкая, 25–49 — низкая, 50–74 — умеренная, 75–94 — высокая, 95–100 — отличная готовность. При низком балле стоит уделить внимание восстановлению; высокий указывает на больший ресурс для сложной тренировки."),
                source: "https://www.garmin.com/en-MY/garmin-technology/running-science-entry-level/after-running/training-readiness/")
        case "sleepScore":
            guard value <= 100 else { return nil }
            let status = score >= 90 ? copy("Excellent sleep", "Отличный сон")
                : score >= 80 ? copy("Good sleep", "Хороший сон")
                : score >= 60 ? copy("Fair sleep", "Удовлетворительный сон") : copy("Poor sleep", "Низкое качество сна")
            return explanation(status, copy(
                "A summary of sleep quality and recovery, including duration, sleep stages and restlessness. Garmin's scale: below 60 poor, 60–79 fair, 80–89 good, 90–100 excellent. Duration alone does not determine the score.",
                "Сводная оценка качества сна и восстановления с учётом длительности, стадий и беспокойства во сне. Шкала Garmin: ниже 60 — низкое качество, 60–79 — удовлетворительно, 80–89 — хорошо, 90–100 — отлично. Одной длительности сна для оценки недостаточно."),
                source: "https://support.garmin.com/en-IN/?faq=mBRMf4ks7XAQ03qtsbI8J6")
        case "stress":
            guard value <= 100 else { return nil }
            let status = score <= 25 ? copy("Resting range", "Диапазон покоя")
                : score <= 50 ? copy("Low stress", "Низкий стресс")
                : score <= 75 ? copy("Medium stress", "Средний стресс") : copy("High stress", "Высокий стресс")
            return explanation(status, copy(
                "This is the day's average physiological stress reported by Garmin, not a live emotion reading. The 0–100 scale uses heart-rate variability: 0–25 resting, 26–50 low, 51–75 medium, 76–100 high. A daily average can hide short peaks and periods of rest.",
                "Это средний физиологический стресс за день по данным Garmin, а не текущая оценка эмоций. Шкала 0–100 основана на вариабельности пульса: 0–25 — покой, 26–50 — низкий, 51–75 — средний, 76–100 — высокий стресс. Среднее за день может скрывать короткие пики и периоды отдыха."),
                source: "https://www8.garmin.com/manuals/webhelp/legacy/EN-US/GUID-9282196F-D969-404D-B678-F48A13D8D0CB.html")
        case "bodyBattery":
            guard value <= 100 else { return nil }
            let status = score <= 25 ? copy("Very low energy reserve", "Очень малый запас энергии")
                : score <= 50 ? copy("Low energy reserve", "Малый запас энергии")
                : score <= 75 ? copy("Moderate energy reserve", "Средний запас энергии") : copy("High energy reserve", "Большой запас энергии")
            return explanation(status, copy(
                "Garmin estimates your available energy using stress, heart-rate variability, sleep and activity. Rest can recharge it; stress and activity can drain it. This is an energy estimate, not a percentage of physical fitness.",
                "Garmin оценивает запас энергии по стрессу, вариабельности пульса, сну и активности. Отдых может восполнять запас, стресс и активность — расходовать. Это оценка энергии, а не процент физической формы."),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-2CF5620C-E585-4E0A-9CC3-9565533EEE4D/EN-US/GUID-87E1392B-2C55-40B7-A1FF-3AB9252DA0A0.html")
        case "recoveryTime":
            return explanation(value == 0 ? copy("Recovery countdown complete", "Отсчёт восстановления завершён") : copy("Until the next hard workout", "До следующей тяжёлой тренировки"), copy(
                "Garmin estimates time until you are ready for another hard workout. It does not require complete inactivity. Sleep, stress and subsequent activity can change the estimate. The value reflects the last Garmin reading.",
                "Garmin оценивает время до готовности к следующей тяжёлой тренировке. Это не требование полного покоя. Сон, стресс и последующая активность могут изменить оценку. Здесь показано последнее полученное значение Garmin."),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-5D183A14-BB43-4A9B-B441-5F824214CE40/EN-US/GUID-DAC27D10-886A-4EA8-8339-674479E9574A.html")
        case "vo2Max":
            return explanation(copy("Aerobic fitness estimate", "Оценка аэробной формы"), copy(
                "Estimated maximum oxygen use per kilogram per minute. Garmin's fitness categories depend on age and sex; this app does not receive enough profile context to assign one. Compare your trend over time under similar conditions rather than judging a single number.",
                "Оценка максимального потребления кислорода на килограмм массы в минуту. Категории Garmin зависят от возраста и пола; приложение не получает достаточно данных профиля, чтобы выбрать категорию. Полезнее сравнивать свою динамику в похожих условиях, чем оценивать одно число."),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-AC520B63-3C82-4266-90F6-6E9F22D5F76E/EN-US/GUID-1FBCCD9E-19E1-4E4C-BD60-1793B5B97EB3.html")
        case "restingHeartRate":
            return explanation(copy("Follow your personal trend", "Ориентир — ваша динамика"), copy("Garmin's daily resting heart rate. Compare several days with your own usual level. Fitness, sleep, stress and recovery can influence it; a lower number is not always better.", "Пульс в покое за день по данным Garmin. Сравнивайте несколько дней со своим привычным уровнем. Форма, сон, стресс и восстановление влияют на пульс; меньше не всегда лучше."))
        case "spo2":
            return explanation(copy("Garmin average oxygen estimate", "Средняя оценка насыщения O₂"), copy("Estimated blood oxygen saturation from the watch. Measurement conditions and altitude affect the result. A single daily average cannot establish a health assessment or show short overnight changes.", "Оценка насыщения крови кислородом по датчику часов. На результат влияют условия измерения и высота. Одно среднее за день не позволяет оценить здоровье или увидеть короткие изменения за ночь."))
        case "respiration":
            return explanation(copy("Average during sleep", "Среднее во сне"), copy("Average breaths per minute during sleep. Compare your own nights and longer-term pattern; this is not your current breathing rate.", "Средняя частота дыхания за время сна. Сравнивайте свои ночи и длительную динамику; это не текущая частота дыхания."))
        case "sleepDuration":
            return explanation(copy("Total time asleep", "Общее время сна"), copy("Time Garmin classified as sleep in the recorded night. It combines light, deep and REM sleep. Consider sleep score and how rested you feel as well as duration.", "Время, которое Garmin определил как сон за эту ночь: лёгкий, глубокий и REM-сон. Вместе с длительностью учитывайте балл сна и ощущение отдыха."))
        case "deepSleep", "remSleep", "lightSleep", "awakeSleep":
            let status = id == "awakeSleep" ? copy("Awake during the sleep period", "Бодрствование в период сна") : copy("Part of the recorded night", "Часть записанной ночи")
            return explanation(status, copy("Garmin estimates sleep stages from sensor data. Stage durations vary between nights, so an isolated value has no universal good/bad threshold. Read it alongside total sleep, sleep score and your pattern over several nights.", "Garmin оценивает стадии сна по данным датчиков. Их длительность меняется от ночи к ночи: у отдельного значения нет универсального порога «хорошо/плохо». Смотрите также на общую длительность, балл сна и динамику за несколько ночей."))
        case "steps":
            var status = copy("Daily walking activity", "Шаги за день")
            if snapshot.retainedMetrics[id] == nil, snapshot.retainedMetrics["stepGoal"] == nil,
               let goal = snapshot.metrics["stepGoal"]?.value, goal.isFinite, goal > 0 {
                status = value >= goal ? copy("Daily goal reached", "Цель на день достигнута") : copy("Toward your daily goal", "Прогресс к дневной цели")
                return explanation(status, copy("Step count compared with your own Garmin daily goal. The goal is a target, not a universal measure of fitness.", "Число шагов относительно вашей дневной цели Garmin. Цель — ориентир активности, а не универсальная оценка формы."), supporting: copy("Goal: ", "Цель: ") + digits(goal))
            }
            return explanation(status, copy("Steps recorded for this day. A personal step goal is needed to assess progress.", "Шаги, записанные за этот день. Для оценки прогресса нужна личная цель по шагам."))
        case "stepGoal":
            return explanation(copy("Your Garmin daily target", "Ваша дневная цель Garmin"), copy("The step target set manually or adjusted automatically by Garmin. It is personal and can change from day to day.", "Цель по шагам, заданная вручную или автоматически Garmin. Она индивидуальна и может меняться день ото дня."))
        case "intensityMinutes":
            return explanation(copy("Weighted activity minutes", "Минуты с учётом интенсивности"), copy("Garmin credits moderate activity minutes and gives vigorous minutes double weight. This daily number can exceed the elapsed workout time; it is not your weekly total.", "Garmin учитывает минуты умеренной активности, а минуты высокой интенсивности засчитывает вдвойне. Число за день может превышать длительность тренировки; это не недельный итог."))
        case "calories":
            return explanation(copy("Resting + active energy", "Покой + активность"), copy("Estimated total energy used during the day, including resting metabolism and activity. This is expenditure, not food intake or a calorie deficit.", "Оценка общего расхода энергии за день, включая обмен в покое и активность. Это расход, а не калории из еды или дефицит калорий."))
        case "activeCalories":
            return explanation(copy("Energy from activity", "Расход от активности"), copy("Estimated energy used through activity beyond resting needs. It is already included in total calories, so the two should not be added together.", "Оценка расхода энергии из-за активности сверх потребностей в покое. Уже входит в общие калории: складывать два показателя не нужно."))
        case "distance":
            return explanation(copy("Daily movement distance", "Дистанция за день"), copy("Distance reported in Garmin's daily summary. It is a daily activity total, not necessarily the distance of your latest workout.", "Дистанция из дневной сводки Garmin. Это итог активности за день, который не обязательно совпадает с дистанцией последней тренировки."))
        case "floors":
            return explanation(copy("Floors climbed", "Поднятые этажи"), copy("Garmin's estimate of floors climbed during the day. It reflects upward movement; it is not the number of flights descended.", "Оценка Garmin числа этажей, на которые вы поднялись за день. Показатель отражает подъём, а не спуск."))
        case "weight":
            return explanation(copy("Latest recorded measurement", "Последнее записанное измерение"), copy("The most recent body-weight measurement available for this record. Single changes can reflect fluid balance and measurement timing. Weight alone does not determine fitness or health.", "Последнее доступное измерение массы тела для этой записи. Отдельные изменения могут зависеть от воды и времени измерения. Сам вес не определяет форму или здоровье."))
        case "hydration":
            return explanation(copy("Logged fluid intake", "Записанная выпитая жидкость"), copy("Fluid intake logged in Garmin Connect. This reflects your entries, not a sensor measurement of hydration or a personal daily requirement.", "Объём жидкости, записанный в Garmin Connect. Это ваши записи, а не измерение гидратации датчиком или индивидуальная суточная потребность."))
        default: return nil
        }
    }

    private static func trainingStatus(_ raw: String?, language: AppLanguage) -> (title: String, detail: String)? {
        guard let raw else { return nil }
        let key = raw.uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let ru = language.effectiveLanguage == .ru
        switch key {
        case "DETRAINING": return ru ? ("Детренированность", "Garmin видит снижение формы после длительного уменьшения тренировок.") : ("Detraining", "Garmin detects declining fitness after an extended reduction in training.")
        case "RECOVERY": return ru ? ("Восстановление", "Сниженная нагрузка даёт организму восстановиться после тяжёлой работы.") : ("Recovery", "Lighter training is allowing recovery from demanding work.")
        case "MAINTAINING": return ru ? ("Поддержание", "Текущие тренировки сохраняют форму без заметного роста.") : ("Maintaining", "Current training maintains fitness without clear improvement.")
        case "PRODUCTIVE": return ru ? ("Продуктивность", "Garmin видит улучшение формы при текущих тренировках.") : ("Productive", "Garmin detects improving fitness with your current training.")
        case "PEAKING": return ru ? ("Пик формы", "Снижение нагрузки помогло восстановиться и выйти на кратковременный пик формы.") : ("Peaking", "Reduced load has supported recovery and a short-lived performance peak.")
        case "OVERREACHING": return ru ? ("Чрезмерная нагрузка", "Нагрузка превышает возможности восстановления и мешает прогрессу.") : ("Overreaching", "Training demands exceed recovery capacity and limit progress.")
        case "UNPRODUCTIVE": return ru ? ("Непродуктивность", "Несмотря на достаточную нагрузку, Garmin видит снижение формы; важны сон, питание и стресс.") : ("Unproductive", "Fitness is declining despite adequate load; sleep, nutrition and stress also matter.")
        case "STRAINED": return ru ? ("Напряжение", "Garmin видит дисбаланс нагрузки и восстановления.") : ("Strained", "Garmin detects an imbalance between training and recovery.")
        case "NO_STATUS", "NONE": return ru ? ("Недостаточно данных", "Garmin пока не накопил достаточно подходящих тренировок для статуса.") : ("No status", "Garmin has not yet collected enough qualifying training data.")
        case "PAUSED": return ru ? ("Статус приостановлен", "Расчёт тренировочного статуса приостановлен в Garmin.") : ("Paused", "Training status evaluation is paused in Garmin.")
        default: return nil
        }
    }
}
