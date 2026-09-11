using XLSX
using DataFrames
using Dates
using Statistics
using Random
using Printf
using Plots
using JSON3

const REQUIRED_COLUMNS = [
    "дата",
    "тикер",
    "цена входа",
    "цена выхода",
    "финрез",
    "комиссия",
]

# Если выгрузки пересекаются по периоду, одинаковые строки могут попасть
# в объединенную выборку несколько раз. true удаляет полные дубликаты.
const DEDUPLICATE_EXACT_ROWS = true

function normalize_column_name(x)
    lowercase(strip(String(x)))
end

function to_float(x)
    if x === missing || x === nothing
        return NaN
    elseif x isa Number
        return Float64(x)
    end

    s = replace(strip(String(x)), " " => "", "," => ".")
    isempty(s) && return NaN
    return parse(Float64, s)
end

function parse_trade_date(x)
    if x isa Date
        return x
    elseif x isa DateTime
        return Date(x)
    end

    s = strip(String(x))

    m2 = match(r"^(\d{2})\.(\d{2})\.(\d{2})$", s)
    if m2 !== nothing
        day = parse(Int, m2.captures[1])
        month = parse(Int, m2.captures[2])
        year = 2000 + parse(Int, m2.captures[3])
        return Date(year, month, day)
    end

    m4 = match(r"^(\d{2})\.(\d{2})\.(\d{4})$", s)
    if m4 !== nothing
        day = parse(Int, m4.captures[1])
        month = parse(Int, m4.captures[2])
        year = parse(Int, m4.captures[3])
        return Date(year, month, day)
    end

    error("Не удалось распознать дату: $s")
end

function find_excel_files(folder::AbstractString)
    files = String[]

    for name in readdir(folder)
        full = joinpath(folder, name)

        if isfile(full) &&
           endswith(lowercase(name), ".xlsx") &&
           !startswith(name, "~\$")
            push!(files, full)
        end
    end

    sort!(files)
    return files
end

function load_one_excel(path::AbstractString)
    raw = DataFrame(XLSX.readtable(path; infer_eltypes=true))

    rename_map = Dict(
        name => Symbol(normalize_column_name(name))
        for name in names(raw)
    )
    rename!(raw, rename_map)

    existing = Set(String.(names(raw)))
    missing_cols = [c for c in REQUIRED_COLUMNS if !(c in existing)]

    if !isempty(missing_cols)
        error(
            "Файл $(basename(path)) не похож на выгрузку дневника. " *
            "Не хватает колонок: " *
            join(missing_cols, ", ")
        )
    end

    df = DataFrame(
        date = parse_trade_date.(raw[!, Symbol("дата")]),
        ticker = strip.(String.(raw[!, Symbol("тикер")])),
        entry_price = to_float.(raw[!, Symbol("цена входа")]),
        exit_price = to_float.(raw[!, Symbol("цена выхода")]),
        gross_pnl = to_float.(raw[!, Symbol("финрез")]),
        commission = abs.(to_float.(raw[!, Symbol("комиссия")])),
        source_file = fill(basename(path), nrow(raw)),
    )

    filter!(
        row -> !(
            isnan(row.entry_price) ||
            isnan(row.exit_price) ||
            isnan(row.gross_pnl) ||
            isnan(row.commission)
        ),
        df,
    )

    df.net_pnl = df.gross_pnl .- df.commission
    return df
end

function load_folder(folder::AbstractString)
    files = find_excel_files(folder)

    isempty(files) && error("В папке нет .xlsx файлов: $folder")

    println()
    println("Найдено Excel-файлов: ", length(files))

    frames = DataFrame[]

    for path in files
        print("Читаю: ", basename(path), " ... ")

        try
            df = load_one_excel(path)
            push!(frames, df)
            println(nrow(df), " строк")
        catch err
            println("ПРОПУЩЕН")
            println("  Причина: ", sprint(showerror, err))
        end
    end

    isempty(frames) && error("Ни один Excel не удалось прочитать.")

    df = vcat(frames...)

    before = nrow(df)

    if DEDUPLICATE_EXACT_ROWS
        unique!(
            df,
            [
                :date,
                :ticker,
                :entry_price,
                :exit_price,
                :gross_pnl,
                :commission,
            ],
        )
    end

    removed = before - nrow(df)

    if removed > 0
        println()
        println("Удалено полных дубликатов: ", removed)
    end

    sort!(df, [:date, :ticker])

    println("Итого сделок в общей выборке: ", nrow(df))
    return df, files
end

function max_streak(values::AbstractVector{<:Real}, positive::Bool)
    best = 0
    current = 0

    for x in values
        good = positive ? x > 0 : x < 0

        if good
            current += 1
            best = max(best, current)
        else
            current = 0
        end
    end

    return best
end

function basic_metrics(df::DataFrame)
    n = nrow(df)
    n == 0 && error("В выборке нет сделок.")

    wins = df.net_pnl[df.net_pnl .> 0]
    losses = df.net_pnl[df.net_pnl .< 0]

    total_win = sum(wins; init=0.0)
    total_loss = abs(sum(losses; init=0.0))

    avg_win = isempty(wins) ? 0.0 : mean(wins)
    avg_loss = isempty(losses) ? 0.0 : abs(mean(losses))

    profit_factor = total_loss == 0 ? Inf : total_win / total_loss
    payoff_ratio = avg_loss == 0 ? Inf : avg_win / avg_loss

    gross_abs = sum(abs.(df.gross_pnl))
    commission_load = gross_abs == 0 ? 0.0 : sum(df.commission) / gross_abs

    return (
        trades = n,
        wins = length(wins),
        losses = length(losses),
        breakeven = count(==(0), df.net_pnl),
        win_rate = length(wins) / n,
        gross_pnl = sum(df.gross_pnl),
        commissions = sum(df.commission),
        net_pnl = sum(df.net_pnl),
        avg_trade = mean(df.net_pnl),
        avg_win = avg_win,
        avg_loss = avg_loss,
        payoff_ratio = payoff_ratio,
        profit_factor = profit_factor,
        best_trade = maximum(df.net_pnl),
        worst_trade = minimum(df.net_pnl),
        max_win_streak = max_streak(df.net_pnl, true),
        max_loss_streak = max_streak(df.net_pnl, false),
        commission_load = commission_load,
    )
end

function daily_table(df::DataFrame)
    daily = combine(
        groupby(df, :date),
        :gross_pnl => sum => :gross_pnl,
        :commission => sum => :commission,
        :net_pnl => sum => :net_pnl,
        nrow => :trades,
    )

    sort!(daily, :date)
    daily.cum_net = cumsum(daily.net_pnl)

    return daily
end

function by_ticker_table(df::DataFrame)
    rows = NamedTuple[]

    for sub in groupby(df, :ticker)
        pnl = sub.net_pnl
        wins = pnl[pnl .> 0]
        losses = pnl[pnl .< 0]

        gross_profit = sum(wins; init=0.0)
        gross_loss = abs(sum(losses; init=0.0))

        push!(rows, (
            ticker = first(sub.ticker),
            trades = nrow(sub),
            win_rate = count(>(0), pnl) / nrow(sub),
            gross_pnl = sum(sub.gross_pnl),
            commission = sum(sub.commission),
            net_pnl = sum(pnl),
            avg_trade = mean(pnl),
            profit_factor = gross_loss == 0 ? Inf : gross_profit / gross_loss,
        ))
    end

    result = DataFrame(rows)
    sort!(result, :net_pnl, rev=true)

    return result
end

function weekday_dates(date_from::Date, date_to::Date)
    result = Date[]

    d = date_from
    while d <= date_to
        if dayofweek(d) <= 5
            push!(result, d)
        end
        d += Day(1)
    end

    return result
end

function complete_daily_sample(
    daily::DataFrame,
    date_from::Date,
    date_to::Date,
)
    weekdays = weekday_dates(date_from, date_to)
    pnl_by_date = Dict(row.date => row.net_pnl for row in eachrow(daily))

    return DataFrame(
        date = weekdays,
        net_pnl = [get(pnl_by_date, d, 0.0) for d in weekdays],
    )
end

function bootstrap_projection(
    daily_pnl::Vector{Float64},
    horizon::Int;
    simulations::Int = 20_000,
    seed::Int = 42,
)
    isempty(daily_pnl) && error("Пустая дневная выборка.")

    rng = MersenneTwister(seed)
    totals = Vector{Float64}(undef, simulations)

    for i in eachindex(totals)
        totals[i] = sum(rand(rng, daily_pnl, horizon))
    end

    return (
        point = mean(daily_pnl) * horizon,
        p05 = quantile(totals, 0.05),
        median = quantile(totals, 0.50),
        p95 = quantile(totals, 0.95),
        probability_profit = mean(totals .> 0),
        samples = totals,
    )
end

function add_equity_columns!(
    daily::DataFrame,
    starting_capital::Union{Nothing,Float64},
)
    if starting_capital === nothing
        daily.equity = copy(daily.cum_net)
        peak = accumulate(max, daily.equity)
        daily.drawdown = daily.equity .- peak
        daily.drawdown_pct = fill(NaN, nrow(daily))
        return
    end

    daily.equity = starting_capital .+ daily.cum_net
    peak = accumulate(max, daily.equity)
    daily.drawdown = daily.equity .- peak

    daily.drawdown_pct = [
        p == 0 ? 0.0 : dd / p
        for (dd, p) in zip(daily.drawdown, peak)
    ]
end

function daily_risk_metrics(
    daily_sample::DataFrame,
    starting_capital,
)
    pnl = daily_sample.net_pnl

    daily_std = length(pnl) > 1 ? std(pnl) : 0.0
    sharpe_like = daily_std == 0 ? NaN : mean(pnl) / daily_std * sqrt(252)

    downside = pnl[pnl .< 0]
    downside_std = length(downside) > 1 ? std(downside) : 0.0
    sortino_like = downside_std == 0 ? NaN : mean(pnl) / downside_std * sqrt(252)

    roi_daily = starting_capital === nothing ? NaN : mean(pnl) / starting_capital

    return (
        avg_daily_pnl = mean(pnl),
        daily_std = daily_std,
        sharpe_like = sharpe_like,
        sortino_like = sortino_like,
        avg_daily_roi = roi_daily,
    )
end

fmt_money(x) = @sprintf("%.2f", x)

function fmt_pct(x)
    isnan(x) && return "n/a"
    @sprintf("%.2f%%", x * 100)
end

function fmt_ratio(x)
    isinf(x) && return "∞"
    isnan(x) && return "n/a"
    @sprintf("%.2f", x)
end

function print_report(
    metrics,
    risk,
    month_proj,
    year_proj,
    sample_days::Int,
    starting_capital,
    daily::DataFrame,
    files::Vector{String},
)
    println()
    println("="^70)
    println("TRADE DIARY ANALYTICS")
    println("="^70)

    println("Excel-файлов:            ", length(files))
    println("Период:                  ", minimum(daily.date), " → ", maximum(daily.date))
    println("Сделок:                  ", metrics.trades)
    println("Плюсовых:                ", metrics.wins)
    println("Минусовых:               ", metrics.losses)
    println("Win rate:                ", fmt_pct(metrics.win_rate))
    println("Gross P&L:               ", fmt_money(metrics.gross_pnl))
    println("Комиссии:                ", fmt_money(metrics.commissions))
    println("Net P&L:                 ", fmt_money(metrics.net_pnl))
    println("Средняя сделка:          ", fmt_money(metrics.avg_trade))
    println("Средний winner:          ", fmt_money(metrics.avg_win))
    println("Средний loser:           ", fmt_money(metrics.avg_loss))
    println("Payoff ratio:            ", fmt_ratio(metrics.payoff_ratio))
    println("Profit factor:           ", fmt_ratio(metrics.profit_factor))
    println("Лучшая сделка:           ", fmt_money(metrics.best_trade))
    println("Худшая сделка:           ", fmt_money(metrics.worst_trade))
    println("Max win streak:          ", metrics.max_win_streak)
    println("Max loss streak:         ", metrics.max_loss_streak)
    println("Commission load:         ", fmt_pct(metrics.commission_load))

    println()
    println("ДНЕВНАЯ СТАТИСТИКА")
    println("Торговых будних дней:    ", sample_days)
    println("Средний P&L / день:      ", fmt_money(risk.avg_daily_pnl))
    println("Дневная σ P&L:           ", fmt_money(risk.daily_std))
    println("Sharpe-like:             ", fmt_ratio(risk.sharpe_like))
    println("Sortino-like:            ", fmt_ratio(risk.sortino_like))
    println("Max drawdown:            ", fmt_money(minimum(daily.drawdown)))

    if starting_capital !== nothing
        println("Стартовый капитал:       ", fmt_money(starting_capital))
        println("P&L / капитал:           ", fmt_pct(metrics.net_pnl / starting_capital))

        valid_dd_pct = filter(!isnan, daily.drawdown_pct)
        if !isempty(valid_dd_pct)
            println("Max drawdown %:          ", fmt_pct(minimum(valid_dd_pct)))
        end
    end

    println()
    println("ЭКСТРАПОЛЯЦИЯ ПРИ ТЕКУЩЕМ РАЗМЕРЕ ПОЗИЦИИ")
    println("Месяц, 21 торг. день:    ", fmt_money(month_proj.point))
    println(
        "  bootstrap 5/50/95%:    ",
        fmt_money(month_proj.p05), " / ",
        fmt_money(month_proj.median), " / ",
        fmt_money(month_proj.p95),
    )
    println("  P(месяц > 0):          ", fmt_pct(month_proj.probability_profit))

    println("Год, 252 торг. дня:      ", fmt_money(year_proj.point))
    println(
        "  bootstrap 5/50/95%:    ",
        fmt_money(year_proj.p05), " / ",
        fmt_money(year_proj.median), " / ",
        fmt_money(year_proj.p95),
    )
    println("  P(год > 0):            ", fmt_pct(year_proj.probability_profit))

    if starting_capital !== nothing
        println("Run-rate ROI / месяц:    ", fmt_pct(month_proj.point / starting_capital))
        println("Run-rate ROI / год:      ", fmt_pct(year_proj.point / starting_capital))
    end

    if sample_days < 20
        println()
        println("⚠ Проекция пока шумная: в выборке меньше 20 торговых дней.")
    end

    println("="^70)
end

function make_plots(
    df::DataFrame,
    daily::DataFrame,
    by_ticker::DataFrame,
    month_proj,
    year_proj,
    output_dir::String,
    starting_capital,
)
    gr()

    equity_title = starting_capital === nothing ?
        "Cumulative Net P&L" :
        "Equity Curve"

    p1 = plot(
        daily.date,
        daily.equity,
        marker=:circle,
        xlabel="Дата",
        ylabel=starting_capital === nothing ? "P&L" : "Капитал",
        title=equity_title,
        label="Net",
        legend=:topleft,
        size=(1100, 600),
        dpi=140,
    )
    savefig(p1, joinpath(output_dir, "01_equity_curve.png"))

    p2 = bar(
        daily.date,
        daily.net_pnl,
        xlabel="Дата",
        ylabel="Net P&L",
        title="Daily Net P&L",
        label="",
        size=(1100, 600),
        dpi=140,
    )
    hline!(p2, [0.0], label="")
    savefig(p2, joinpath(output_dir, "02_daily_pnl.png"))

    p3 = plot(
        daily.date,
        daily.drawdown,
        xlabel="Дата",
        ylabel="Drawdown",
        title="Drawdown",
        label="DD",
        size=(1100, 600),
        dpi=140,
    )
    hline!(p3, [0.0], label="")
    savefig(p3, joinpath(output_dir, "03_drawdown.png"))

    if nrow(by_ticker) > 0
        p4 = bar(
            by_ticker.ticker,
            by_ticker.net_pnl,
            xlabel="Тикер",
            ylabel="Net P&L",
            title="P&L by Ticker",
            label="",
            xrotation=45,
            size=(1100, 650),
            dpi=140,
        )
        hline!(p4, [0.0], label="")
        savefig(p4, joinpath(output_dir, "04_ticker_pnl.png"))
    end

    p5 = histogram(
        df.net_pnl,
        bins=:auto,
        xlabel="Net P&L сделки",
        ylabel="Количество",
        title="Trade P&L Distribution",
        label="",
        size=(1100, 600),
        dpi=140,
    )
    vline!(p5, [0.0], label="")
    savefig(p5, joinpath(output_dir, "05_trade_pnl_distribution.png"))

    p6 = histogram(
        month_proj.samples,
        bins=50,
        xlabel="P&L за 21 торговый день",
        ylabel="Симуляции",
        title="Bootstrap Monthly Projection",
        label="",
        size=(1100, 600),
        dpi=140,
    )
    vline!(p6, [0.0], label="")
    savefig(p6, joinpath(output_dir, "06_month_projection.png"))

    p7 = histogram(
        year_proj.samples,
        bins=50,
        xlabel="P&L за 252 торговых дня",
        ylabel="Симуляции",
        title="Bootstrap Yearly Projection",
        label="",
        size=(1100, 600),
        dpi=140,
    )
    vline!(p7, [0.0], label="")
    savefig(p7, joinpath(output_dir, "07_year_projection.png"))
end

function write_tsv(path::AbstractString, table::DataFrame)
    open(path, "w") do io
        println(io, join(names(table), '\t'))

        for row in eachrow(table)
            println(
                io,
                join(
                    [replace(string(v), '\t' => ' ') for v in row],
                    '\t',
                ),
            )
        end
    end
end

function save_tables(
    df::DataFrame,
    daily::DataFrame,
    by_ticker::DataFrame,
    files::Vector{String},
    output_dir::String,
)
    write_tsv(joinpath(output_dir, "trades_enriched.tsv"), df)
    write_tsv(joinpath(output_dir, "daily.tsv"), daily)
    write_tsv(joinpath(output_dir, "by_ticker.tsv"), by_ticker)

    open(joinpath(output_dir, "sources.txt"), "w") do io
        for path in files
            println(io, path)
        end
    end
end


function json_safe(x)
    if x isa AbstractFloat && !isfinite(x)
        return nothing
    end
    return x
end

function projection_json(proj, horizon_days::Int)
    Dict(
        "horizon_trading_days" => horizon_days,
        "point_estimate" => json_safe(proj.point),
        "bootstrap_p05" => json_safe(proj.p05),
        "bootstrap_median" => json_safe(proj.median),
        "bootstrap_p95" => json_safe(proj.p95),
        "probability_profit" => json_safe(proj.probability_profit),
    )
end

function save_json_report(
    df::DataFrame,
    daily::DataFrame,
    by_ticker::DataFrame,
    metrics,
    risk,
    month_proj,
    year_proj,
    sample_days::Int,
    starting_capital,
    files::Vector{String},
    output_dir::AbstractString,
)
    valid_dd_pct = filter(!isnan, daily.drawdown_pct)
    max_drawdown_pct = isempty(valid_dd_pct) ? nothing : minimum(valid_dd_pct)

    report = Dict(
        "meta" => Dict(
            "generated_at" => Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"),
            "source_files" => basename.(files),
            "source_file_count" => length(files),
            "period_from" => string(minimum(daily.date)),
            "period_to" => string(maximum(daily.date)),
            "sample_weekdays" => sample_days,
            "starting_capital" => starting_capital,
            "deduplicate_exact_rows" => DEDUPLICATE_EXACT_ROWS,
        ),
        "summary" => Dict(
            "trades" => metrics.trades,
            "wins" => metrics.wins,
            "losses" => metrics.losses,
            "breakeven_trades" => metrics.breakeven,
            "win_rate" => json_safe(metrics.win_rate),
            "gross_pnl" => json_safe(metrics.gross_pnl),
            "commissions" => json_safe(metrics.commissions),
            "net_pnl" => json_safe(metrics.net_pnl),
            "avg_trade" => json_safe(metrics.avg_trade),
            "avg_win" => json_safe(metrics.avg_win),
            "avg_loss" => json_safe(metrics.avg_loss),
            "payoff_ratio" => json_safe(metrics.payoff_ratio),
            "profit_factor" => json_safe(metrics.profit_factor),
            "best_trade" => json_safe(metrics.best_trade),
            "worst_trade" => json_safe(metrics.worst_trade),
            "max_win_streak" => metrics.max_win_streak,
            "max_loss_streak" => metrics.max_loss_streak,
            "commission_load" => json_safe(metrics.commission_load),
            "max_drawdown" => json_safe(minimum(daily.drawdown)),
            "max_drawdown_pct" => json_safe(max_drawdown_pct),
            "roi_total" => starting_capital === nothing ? nothing : json_safe(metrics.net_pnl / starting_capital),
        ),
        "daily_risk" => Dict(
            "avg_daily_pnl" => json_safe(risk.avg_daily_pnl),
            "daily_pnl_std" => json_safe(risk.daily_std),
            "sharpe_like" => json_safe(risk.sharpe_like),
            "sortino_like" => json_safe(risk.sortino_like),
            "avg_daily_roi" => json_safe(risk.avg_daily_roi),
        ),
        "projections" => Dict(
            "month" => projection_json(month_proj, 21),
            "year" => projection_json(year_proj, 252),
            "method" => "bootstrap resampling of historical weekday P&L",
            "simulations" => 20_000,
            "position_sizing" => "constant",
        ),
        "by_ticker" => [
            Dict(
                "ticker" => row.ticker,
                "trades" => row.trades,
                "win_rate" => json_safe(row.win_rate),
                "gross_pnl" => json_safe(row.gross_pnl),
                "commission" => json_safe(row.commission),
                "net_pnl" => json_safe(row.net_pnl),
                "avg_trade" => json_safe(row.avg_trade),
                "profit_factor" => json_safe(row.profit_factor),
            )
            for row in eachrow(by_ticker)
        ],
        "daily" => [
            Dict(
                "date" => string(row.date),
                "trades" => row.trades,
                "gross_pnl" => json_safe(row.gross_pnl),
                "commission" => json_safe(row.commission),
                "net_pnl" => json_safe(row.net_pnl),
                "cum_net" => json_safe(row.cum_net),
                "equity" => json_safe(row.equity),
                "drawdown" => json_safe(row.drawdown),
                "drawdown_pct" => json_safe(row.drawdown_pct),
            )
            for row in eachrow(daily)
        ],
        "trades" => [
            Dict(
                "date" => string(row.date),
                "ticker" => row.ticker,
                "entry_price" => json_safe(row.entry_price),
                "exit_price" => json_safe(row.exit_price),
                "gross_pnl" => json_safe(row.gross_pnl),
                "commission" => json_safe(row.commission),
                "net_pnl" => json_safe(row.net_pnl),
                "source_file" => row.source_file,
            )
            for row in eachrow(df)
        ],
    )

    json_path = joinpath(output_dir, "report.json")
    open(json_path, "w") do io
        JSON3.write(io, report)
        println(io)
    end
    return json_path
end

function ask_starting_capital()
    print("Стартовый капитал для ROI (Enter = пропустить): ")
    raw = strip(readline())

    isempty(raw) && return nothing
    return parse(Float64, replace(raw, "," => "."))
end

function main()
    println("Julia Trade Diary Analytics")
    println()

    folder = if !isempty(ARGS)
        ARGS[1]
    else
        print("Папка с Excel-выгрузками: ")
        strip(readline())
    end

    if !isdir(folder)
        error("Папка не найдена: $folder")
    end

    starting_capital = ask_starting_capital()

    df, files = load_folder(folder)

    metrics = basic_metrics(df)
    daily = daily_table(df)
    by_ticker = by_ticker_table(df)

    date_from = minimum(df.date)
    date_to = maximum(df.date)

    sample = complete_daily_sample(
        daily,
        date_from,
        date_to,
    )

    add_equity_columns!(daily, starting_capital)
    risk = daily_risk_metrics(sample, starting_capital)

    month_proj = bootstrap_projection(
        Float64.(sample.net_pnl),
        21,
    )

    year_proj = bootstrap_projection(
        Float64.(sample.net_pnl),
        252,
    )

    stamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    output_dir = joinpath(
        folder,
        "analytics",
        "combined_$stamp",
    )
    mkpath(output_dir)

    print_report(
        metrics,
        risk,
        month_proj,
        year_proj,
        nrow(sample),
        starting_capital,
        daily,
        files,
    )

    make_plots(
        df,
        daily,
        by_ticker,
        month_proj,
        year_proj,
        output_dir,
        starting_capital,
    )

    save_tables(
        df,
        daily,
        by_ticker,
        files,
        output_dir,
    )

    json_path = save_json_report(
        df,
        daily,
        by_ticker,
        metrics,
        risk,
        month_proj,
        year_proj,
        nrow(sample),
        starting_capital,
        files,
        output_dir,
    )

    println()
    println("JSON-отчет:")
    println(json_path)

    println()
    println("Готово.")
    println("Аналитика сохранена в:")
    println(output_dir)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
