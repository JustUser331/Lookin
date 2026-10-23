# Сравнение Lookin на Simulator — 23 октября 2026

Официальный Lookin 1.0.6 + LookinServer 1.2.8 через SPM против Lookin MCP build 20 с внешним breakpoint. Один выделенный iPhone 16 Pro Simulator, iOS 18.6 arm64. По 3 первых захвата и 3 GUI Reload на каждый вариант. Все значения — медианы, мс; меньше лучше.

## Первое получение после перезапуска

| Этап | Официальный + SPM | Наш Full + breakpoint | Наш Hybrid + breakpoint |
|---|---:|---:|---:|
| Дерево | 46.16 | 33.74 | 10.74 |
| Рабочее превью | 530.62 | 577.83 | 62.23 |
| Все видимые отдельные текстуры | 530.62 | 577.97 | 692.27 |
| Полный снимок | 620.95 | 650.59 | 827.52 |

Диапазон полного снимка: official 620.38–629.61 мс; full 625.12–675.56 мс; hybrid 707.96–834.89 мс.

## Повторный Reload

| Этап | Официальный + SPM | Наш Full + breakpoint | Наш Hybrid + breakpoint |
|---|---:|---:|---:|
| Дерево | 72.05 | 66.93 | 54.22 |
| Рабочее превью | 574.95 | 314.25 | 128.17 |
| Все видимые отдельные текстуры | 574.95 | 314.42 | 416.60 |
| Полный снимок | 637.39 | 384.05 | 603.65 |

Диапазон полного снимка: official 540.26–648.65 мс; full 381.55–389.67 мс; hybrid 544.74–634.79 мс.

## Интерпретация

Hybrid ускоряет рабочее превью в 8.53 раза при первом захвате и в 4.49 раза при Reload. Это временный общий снимок сцены; готовность отдельных текстур измерена отдельно.

Full сокращает время полного Reload на 39.7%. Первое полное получение Full на 4.8% дольше официального. Первое полное получение Hybrid на 33.3% дольше официального.

Breakpoint/dlopen отдельно: медиана 63.71 мс, диапазон 57.31–74.71 мс. Сюда входит исполнение выражения LLDB; это не весь запуск приложения и не всё подключение отладчика.

Во всех 18 снимках совпало покрытие: 35 узлов (33 физических, 2 пользовательских), атрибуты 33 узлов, 32 групповых и 17 отдельных изображений. В первом захвате отображалось 18 элементов, после Reload — 17, одинаково для всех вариантов. Пиксельное равенство в этой серии не проверялось.

## Ограничения

- Small static synthetic scene: 35 nodes, 33 physical; results do not establish performance on a large production screen.
- First means app and client restart, not OS cache flush.
- Times begin at hierarchy request; app launch, discovery, debugger setup and operator click delays excluded.
- Working Hybrid preview is group overview; all individual visible textures reported separately. GPU presentation not measured.
- Official metadata readiness is an upper bound at full task completion.
- Same observer in both clients; instrumentation overhead included. Official completion uses existing completion/error signals.
- SPM server Debug (-Onone) versus optimized framework Release. This compares workflows, not linkage alone.
- Interactive mode is intentionally partial and is not included in complete-snapshot comparison.
- Only 3 samples per metric; small differences and overlapping ranges should not be treated as robust gains.

Официальный клиент измерен на копии с изменённой подписью для подключения наблюдателя. Хеш секции машинного кода совпадает с оригиналом; см. official-code-identity.json. Установленные сборки не изменялись. Данные всех 18 захватов и версии клиентов/серверов сохранены в comparison.json. Полные исходные журналы и измерительные скрипты находятся в workspace: analysis/evidence/simulator-release-comparison-20261023/. Пилотные серии исключены; все 18 учтённых захватов сохранены.
