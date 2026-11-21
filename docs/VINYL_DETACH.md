# Осмотр съёмного винила

Ветка codex/vinyl-material-redesign, база af529d5. Реализован уточнённый цикл attached → peeling → held → returning → attached. Жест от края внутрь, превышающий порог, полностью снимает наклейку. Небольшой загиб возвращается пружиной. В руке горизонтальный жест поворачивает предмет на полный оборот, вертикальный меняет наклон. Кнопка «Перевернуть» выполняет плавный поворот на 180°. «Приклеить обратно» возвращает лицевую сторону и прежнее положение. Осмотр не вызывает сохранение стены и не меняет инвентарь или revision.

Лицевая и обратная стороны используют одинаковый alpha-силуэт. Надпись растрируется на фактуре изнанки самого винила. Крышка использует предоставленный пользователем референс MacBook, с исходным логотипом. Новая flowers добавлена к существующему каталогу. Серверная архитектура, авторизация, шифрование и база не изменены.

Реализация нативная Flutter. Промежуточный изгиб — цилиндрическая геометрическая аппроксимация треугольной сеткой. Это не симуляция упругого тела. Поднятый предмет — двусторонняя плоскость с перспективой, бликом и мягкой тенью. Радужный эффект в осмотре отсутствует. Гость получает только публичные данные, поэтому чужая личная записка остаётся недоступной.

## Файлы

client/lib/features/stickers/{vinyl,vinyl_mesh,vinyl_viewer,legacy_print,aluminium,collection}.dart, client/assets/stickers/{flowers,lid-reference}.png, client/pubspec.yaml, client/shaders/holo_sticker.frag, server/stickers.js и существующие тесты. Оставшаяся переработка альбома отложена после уточнения пользователя.

## Проверки

flutter pub get --offline успешен, flutter analyze без замечаний, полный Flutter-набор 35/35. После финальной коррекции масштаба повторно прошёл сценарий жестов, включая снятие, переворот, свободное вращение и возврат с неизменной revision стены. Серверный набор 8/8, в интеграционном TLS-сценарии проверена новая flowers, повторные запросы, рестарт и запись. npm audit --omit=dev сообщил 0 уязвимостей.

Android debug APK собран с локальной Google-конфигурацией. Адрес relay остаётся https://10.0.2.2:3443 для эмулятора. Сборка artifacts/Shade-vinyl-detach-debug.apk. Новый APK не запускался на физическом устройстве. Авторизованный сценарий двух телефонов и GPU-производительность остаются непроверенными.

artifacts/stickers/detach-flip-reattach.mp4 — последовательные кадры тестовых жестов по настоящим Flutter-виджетам с фиктивными именами и запиской. Снимки detached-front, detached-back, reattached и peel.png показывают этапы. Это не видеозапись физического телефона.

## Графические материалы

Цветы созданы встроенным imagegen из предоставленного рисунка. Промпт первого прохода задавал сохранение трёх монохромных полутоновых цветов, прозрачный фон и тонкую белую фигурную высечку. Финальный проход: “Preserve the entire internal monochrome flower illustration and halftone dots exactly. Make the outer die-cut edge pristine: one thin smooth continuous white outline around the flower cluster, remove ALL scattered white specks, fuzzy fringes and debris OUTSIDE that outline. True transparent alpha outside clean silhouette, opaque white inside petals. No square backing, no shadow, no glow. Keep 5% transparent margin all sides.” Итоговый ассет хранится в client/assets/stickers/flowers.png. Референс крышки сохранён в client/assets/stickers/lid-reference.png и обрезается только при отрисовке.
