# Trade Diary Analytics

Небольшой локальный инструмент для анализа торгового дневника 
```bash
https://github.com/Jeanorochka/moex-trade-diary
```
## Requirements

```bash
julia -e "import Pkg; Pkg.add([\"XLSX\", \"DataFrames\", \"Plots\", \"JSON3\"])"
```
## Для анализа дневника и моделирования доходности :

1. Python выгружает сделки брокера в Excel.
2. Julia читает все `.xlsx` из папки `exports/`.
3. Склеивает сделки в одну выборку.
4. Удаляет точные дубликаты.
5. Считает P&L, комиссии, win rate, drawdown, Sharpe-like, Profit Factor и другие метрики.
6. Делает bootstrap-прогноз на месяц и год.
7. Сохраняет графики, таблицы и `report.json`.

Не ИИР. 

