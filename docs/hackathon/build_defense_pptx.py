# -*- coding: utf-8 -*-
"""Генератор презентации Shade для защиты на хакатоне «ТехноНаставники» (23.11.2026)."""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from pptx.oxml.ns import qn
import os

ROOT = r"C:\Users\Kait1x\Documents\Shade"
SHOT = os.path.join(ROOT, "docs", "hackathon", "screenshots")
LOGO = os.path.join(ROOT, "outputs", "telegram", "shade-avatar-1024.png")
OUT = os.path.join(ROOT, "docs", "hackathon", "Shade_Akseleratory_presentation_v3.pptx")

BLACK = RGBColor(0x00, 0x00, 0x00)
SURFACE = RGBColor(0x11, 0x11, 0x13)
BORDER = RGBColor(0x29, 0x29, 0x2D)
TEXT = RGBColor(0xF5, 0xF5, 0xF7)
SECOND = RGBColor(0x8E, 0x8E, 0x93)
VIOLET = RGBColor(0x8B, 0x5C, 0xF6)
GREEN = RGBColor(0x3D, 0xDC, 0x84)

FONT = "Segoe UI"
MONO = "Consolas"

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]


def slide():
    s = prs.slides.add_slide(BLANK)
    s.background.fill.solid()
    s.background.fill.fore_color.rgb = BLACK
    return s


def box(s, x, y, w, h):
    tb = s.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    return tb, tf


def run(p, text, size=16, color=TEXT, bold=False, font=FONT):
    r = p.add_run()
    r.text = text
    r.font.size = Pt(size)
    r.font.color.rgb = color
    r.font.bold = bold
    r.font.name = font
    return r


def title(s, text, kicker=None):
    if kicker:
        tb, tf = box(s, 0.6, 0.35, 12.1, 0.4)
        run(tf.paragraphs[0], kicker.upper(), 13, VIOLET, True)
    tb, tf = box(s, 0.6, 0.72, 12.1, 0.9)
    run(tf.paragraphs[0], text, 30, TEXT, True)
    ln = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(0.62), Inches(1.52), Inches(1.1), Pt(3))
    ln.fill.solid(); ln.fill.fore_color.rgb = VIOLET; ln.line.fill.background()


def bullets(s, items, x=0.6, y=1.85, w=12.1, h=5.0, size=17, gap=8):
    tb, tf = box(s, x, y, w, h)
    first = True
    for it in items:
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.space_after = Pt(gap)
        if isinstance(it, tuple):
            head, rest = it
            run(p, "▪ ", size, VIOLET, True)
            run(p, head, size, TEXT, True)
            run(p, rest, size, SECOND)
        else:
            run(p, "▪ ", size, VIOLET, True)
            run(p, it, size, TEXT)
    return tb


def footer(s, n):
    tb, tf = box(s, 0.6, 7.08, 12.1, 0.35)
    p = tf.paragraphs[0]
    run(p, "SHADE · хакатон «ТехноНаставники» · концерн «Созвездие»", 11, SECOND)
    run(p, f"    {n:02d}", 11, SECOND)


def notes(s, text):
    s.notes_slide.notes_text_frame.text = text


def card(s, x, y, w, h, head, body, accent=VIOLET):
    sh = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(x), Inches(y), Inches(w), Inches(h))
    sh.fill.solid(); sh.fill.fore_color.rgb = SURFACE
    sh.line.color.rgb = BORDER; sh.line.width = Pt(1)
    sh.adjustments[0] = 0.06
    tf = sh.text_frame
    tf.word_wrap = True
    tf.margin_left = Inches(0.18); tf.margin_right = Inches(0.18)
    tf.margin_top = Inches(0.14); tf.margin_bottom = Inches(0.1)
    tf.vertical_anchor = MSO_ANCHOR.TOP
    p = tf.paragraphs[0]
    p.alignment = PP_ALIGN.LEFT
    run(p, head, 16, accent, True)
    for line in body:
        p = tf.add_paragraph()
        p.alignment = PP_ALIGN.LEFT
        p.space_before = Pt(4)
        run(p, line, 13.5, TEXT)
    return sh


def pic(s, name, x, y, h):
    return s.shapes.add_picture(os.path.join(SHOT, name), Inches(x), Inches(y), height=Inches(h))


# ── 1. Титул ──────────────────────────────────────────────────────────────
s = slide()
s.shapes.add_picture(LOGO, Inches(0.6), Inches(0.55), height=Inches(1.5))
tb, tf = box(s, 2.4, 0.62, 10.3, 1.0)
run(tf.paragraphs[0], "SHADE", 54, TEXT, True)
tb, tf = box(s, 2.4, 1.62, 10.3, 0.6)
run(tf.paragraphs[0], "Приватный мессенджер с собственным сервером и сквозным шифрованием", 20, SECOND)
tb, tf = box(s, 0.6, 2.9, 12.1, 1.6)
p = tf.paragraphs[0]; p.space_after = Pt(10)
run(p, "Хакатон «ТехноНаставники» · кейс «Мессенджер» · концерн «Созвездие»", 18, TEXT, True)
p = tf.add_paragraph(); p.space_after = Pt(10)
run(p, "Автор и разработчик: школьник, команда «Shade» · защита 23 ноября 2026", 16, SECOND)
p = tf.add_paragraph()
run(p, "Живая демо-версия: ", 16, SECOND)
run(p, "https://alpha.shadechat.ru", 16, VIOLET, True)
card(s, 0.6, 4.7, 3.9, 1.9, "Android + Web/PWA", ["Flutter-клиент и браузерная версия", "с общим интерфейсом"])
card(s, 4.7, 4.7, 3.9, 1.9, "Свой сервер", ["Node.js + Express + Socket.IO", "две версии протокола, v1 и v2"])
card(s, 8.8, 4.7, 3.9, 1.9, "E2EE по умолчанию", ["RSA-4096 + AES-256-GCM", "ключи не покидают устройство"])
footer(s, 1)
notes(s, "0:00–0:30. Поздороваться, представиться. Одна фраза: «Я написал мессенджер с нуля: клиент, сервер и шифрование. Он работает прямо сейчас — ссылка на экране». Не читать слайд.")

# ── 2. Команда и роли ─────────────────────────────────────────────────────
s = slide()
title(s, "Команда и как мы распределили работу", "о команде")
card(s, 0.6, 1.9, 3.95, 3.3, "Я — разработчик", [
    "Вся техническая часть: архитектура,", "Flutter-клиент, JS-ядро PWA,", "оба сервера, криптография,",
    "тесты, деплой и поддержка staging"])
card(s, 4.7, 1.9, 3.95, 3.3, "Ребята из команды", [
    "Обсуждение идеи и сценариев,", "тестирование на своих телефонах,", "обратная связь по интерфейсу,",
    "помощь с подготовкой защиты"])
card(s, 8.8, 1.9, 3.95, 3.3, "Наставник", [
    "Консультации по направлению,", "ревью решений,", "дорожная карта кейса"])
tb, tf = box(s, 0.6, 5.5, 12.1, 1.3)
p = tf.paragraphs[0]; p.space_after = Pt(6)
run(p, "Материалы кейса в работе: ", 16, TEXT, True)
run(p, "прошёл дорожную карту «от простого к сложному»; изучил референсы ChatterApp и Simple Chat", 16, SECOND)
p = tf.add_paragraph()
run(p, "(Kotlin + Compose + Firebase, MVVM) — взял структуру фич и разделение UI / данные / логика, реализовал на своём стеке.", 16, SECOND)
footer(s, 2)
notes(s, "0:30–1:00. Спокойно, без оправданий: «Я вёл всю техническую часть, ребята участвовали в обсуждении и тестировании». Подчеркнуть использование материалов кейса — это отдельный критерий оценки.")

# ── 3. Проблема ───────────────────────────────────────────────────────────
s = slide()
title(s, "Проблема: что скрывается за интерфейсом мессенджера", "проблема")
bullets(s, [
    ("За «чатиком» — сложные технологии: ", "базы данных, синхронизация в реальном времени, авторизация, безопасность."),
    ("Большинство мессенджеров хранят переписку так, ", "что сервер провайдера технически может её прочитать."),
    ("Школьник редко строит приложение «от и до» — ", "с авторизацией, базой и реальной синхронизацией между устройствами."),
    ("Готовые облака (Firebase) прячут принципы ", "клиент-серверного взаимодействия за SDK — а кейс просит их показать."),
], y=1.95, size=19, gap=16)
tb, tf = box(s, 0.6, 5.6, 12.1, 1.0)
run(tf.paragraphs[0], "Мессенджер — идеальный учебный проект: он охватывает все ключевые аспекты мобильной разработки.", 18, VIOLET, True)
footer(s, 3)
notes(s, "1:00–1:30. Говорить как про личную мотивацию: «Мне стало интересно, как это устроено на самом деле, и я решил построить всё сам — включая сервер». Последняя строка — мостик к слайду «почему не Firebase».")

# ── 4. Идея ───────────────────────────────────────────────────────────────
s = slide()
title(s, "Идея: свой мессенджер, свой сервер, E2EE", "идея")
bullets(s, [
    ("Shade — полноценный продуктовый прототип: ", "Android-приложение + веб-версия (PWA) для iPhone и Android."),
    ("Собственный сервер на Node.js: ", "я сам реализовал сессии, доставку, квитанции, лимиты и переподключение."),
    ("E2EE — не опция, а основа: ", "сообщения шифруются на устройстве, сервер видит только шифротекст."),
    ("Это не макет: ", "живой staging alpha.shadechat.ru, реальные тестеры на iPhone и Samsung, закрытая бета."),
], y=1.95, size=19, gap=16)
card(s, 0.6, 5.35, 12.1, 1.35, "Что сверх ТЗ", [
    "Тёмная AMOLED-тема · push (FCM) · «печатает…» и «в сети» · поиск · стикеры · мультиустройство (до 8) · recovery-пакет и Face ID"], accent=GREEN)
footer(s, 4)
notes(s, "1:30–2:00. Ключевая мысль: требования ТЗ закрыты полностью, а бонусы перевыполнены — вместо симметричного шифрования по фразе сделано полноценное E2EE. Упомянуть живого тестера — это критерий «практическая ценность».")

# ── 5. Пользовательский путь ──────────────────────────────────────────────
s = slide()
title(s, "Пользовательский путь", "путь пользователя")
bullets(s, [
    ("Регистрация и вход: ", "Google-аккаунт (подтверждённый email) + пароль-фраза устройства; ключи создаются локально."),
    ("Список чатов: ", "диалоги, поиск, «Избранное», последние сообщения и статусы."),
    ("Диалог: ", "история, текст в реальном времени, ответ на сообщение, фото из галереи/камеры."),
    ("«Прочитано»: ", "галочки после расшифровки и сохранения на устройстве собеседника."),
    ("Офлайн: ", "история читается без сети; новые сообщения ждут в очереди и доставляются при возврате сети."),
], x=0.6, y=1.9, w=7.3, size=16.5, gap=12)
pic(s, "chats.png", 8.35, 1.75, 5.1)
pic(s, "conversation.png", 10.85, 1.75, 5.1)
footer(s, 5)
notes(s, "2:00–2:40. Вести пальцем по скриншотам: список чатов → диалог. Отметить «Подключено · E2EE» внизу и двойные галочки. Каждый пункт пути соответствует требованию ТЗ — сказать это явно.")

# ── 6. Архитектура и синхронизация ────────────────────────────────────────
s = slide()
title(s, "Как устроено: свой сервер и честная синхронизация", "как работает")
# diagram
def dbox(x, y, w, h, head, lines):
    sh = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(x), Inches(y), Inches(w), Inches(h))
    sh.fill.solid(); sh.fill.fore_color.rgb = SURFACE; sh.line.color.rgb = BORDER; sh.line.width = Pt(1)
    sh.adjustments[0] = 0.08
    tf = sh.text_frame; tf.word_wrap = True
    tf.margin_left = Inches(0.12); tf.margin_right = Inches(0.12); tf.margin_top = Inches(0.08)
    p = tf.paragraphs[0]; p.alignment = PP_ALIGN.LEFT; run(p, head, 14.5, VIOLET, True)
    for ln in lines:
        p = tf.add_paragraph(); p.alignment = PP_ALIGN.LEFT; run(p, ln, 12, TEXT)
    return sh
dbox(0.6, 1.95, 3.6, 1.75, "Android (Flutter)", ["Riverpod + CryptoService", "SQLCipher: шифрованная история", "протокол v1"])
dbox(4.55, 1.95, 4.2, 1.75, "Сервер (Node.js)", ["v1 relay :3000 · v2 alpha :3101", "Express + Socket.IO + TLS", "хранит только шифротекст"])
dbox(9.1, 1.95, 3.6, 1.75, "Web/PWA (браузер)", ["JS-ядро владеет ключами (WebCrypto)", "Flutter UI — проекция данных", "протокол v2: до 8 устройств"])
ln1 = s.shapes.add_connector(1, Inches(4.2), Inches(2.82), Inches(4.55), Inches(2.82))
ln1.line.color.rgb = VIOLET; ln1.line.width = Pt(1.5)
ln2 = s.shapes.add_connector(1, Inches(8.75), Inches(2.82), Inches(9.1), Inches(2.82))
ln2.line.color.rgb = VIOLET; ln2.line.width = Pt(1.5)
tb, tf = box(s, 3.2, 3.85, 7.0, 0.4)
p = tf.paragraphs[0]; p.alignment = PP_ALIGN.CENTER
run(p, "только зашифрованные конверты + подписи операций", 12.5, SECOND)
bullets(s, [
    ("Real-time: ", "Socket.IO-сигналы + подписанный HTTP-fetch каждые 15 с и после reconnect."),
    ("Надёжность: ", "подписанный outbox; повтор отправляет тот же ciphertext и ID — без дублей."),
    ("Квитанции: ", "«доставлено» — после подписанного ACK устройства (расшифровка + атомарная запись)."),
    ("Zero-knowledge: ", "даже полный доступ к серверу не даёт прочитать переписку — ключей там нет."),
], y=4.4, size=15.5, gap=8)
footer(s, 6)
notes(s, "2:40–3:20. Главный инженерный слайд. Объяснить связку: JS владеет ключами, Flutter рисует; сервер — «глухой ретранслятор». Синхронизация не «магия облака», а понятный протокол: сигнал + fetch + очередь + ACK. Это и есть принципы клиент-серверного взаимодействия из цели кейса.")

# ── 7. Почему не Firebase ─────────────────────────────────────────────────
s = slide()
title(s, "Почему свой сервер, а не Firebase", "обоснование решения")
card(s, 0.6, 1.95, 5.95, 3.6, "Firebase по методичке", [
    "Готовое облако: Auth + Database + Storage", "SDK скрывает транспорт и синхронизацию",
    "Сообщения в облаке доступны провайдеру", "Быстро для MVP — но принципы не видны"], accent=SECOND)
card(s, 6.75, 1.95, 5.95, 3.6, "Свой сервер Shade", [
    "Сам написал сессии, доставку, ACK, лимиты", "Каждый принцип клиент-сервер виден в коде",
    "E2EE: сервер физически не читает сообщения", "Полный контроль над данными и инфраструктурой"], accent=VIOLET)
tb, tf = box(s, 0.6, 5.85, 12.1, 1.1)
p = tf.paragraphs[0]; p.space_after = Pt(6)
run(p, "Цель кейса — показать принципы клиент-серверного взаимодействия. ", 17, TEXT, True)
run(p, "Собственный сервер демонстрирует их глубже, чем готовое облако.", 17, SECOND)
p = tf.add_paragraph()
run(p, "Стек (Flutter + Node.js) согласован индивидуально; Firebase использую там, где уместен — push-уведомления FCM.", 15, SECOND)
footer(s, 7)
notes(s, "3:20–3:50. Это ожидаемый вопрос жюри — отвечаю на него со слайда, уверенно. Не ругать Firebase: «отличный инструмент для быстрого MVP, но для учебной цели и для приватности я выбрал свой сервер». Тон — инженерный выбор, а не оппозиция.")

# ── 8. Шифрование ─────────────────────────────────────────────────────────
s = slide()
title(s, "Шифрование: ключи только на устройстве", "безопасность")
bullets(s, [
    ("1. Идентичность: ", "RSA-4096 генерируется на устройстве; приватный ключ — в шифрованном хранилище (PBKDF2, 600 000 итераций)."),
    ("2. Сообщение: ", "случайный AES-256 ключ + AES-GCM (тег 16 байт — подделка обнаруживается)."),
    ("3. Конверт: ", "AES-ключ шифруется публичным ключом получателя — RSA-OAEP-SHA256; для каждого устройства отдельно."),
    ("4. Подпись: ", "RSA-PSS-SHA256 — получатель проверяет отправителя и целостность."),
    ("5. Доставка: ", "сервер передаёт шифротекст; ACK ставится только после расшифровки и сохранения."),
], y=1.9, size=16.5, gap=10)
card(s, 0.6, 5.35, 5.95, 1.5, "Защита от подмены ключей", [
    "Отпечаток ключа сверяется по независимому каналу;", "до сверки отправка контакту заблокирована (fail-closed)"])
card(s, 6.75, 5.35, 5.95, 1.5, "Честно об ограничениях", [
    "Forward secrecy (Double Ratchet) — следующий этап;", "метаданные видны серверу, содержимое — нет"], accent=SECOND)
footer(s, 8)
notes(s, "3:50–4:30. Профильный слайд для жюри оборонного концерна. Объяснить «конверт внутри сейфа» простыми словами. Самому поднять ограничение PFS — честность усиливает доверие. Детали — в комментариях crypto_service.dart и в пояснительной записке.")

# ── 9. Интерфейс и функции ────────────────────────────────────────────────
s = slide()
title(s, "Интерфейс: премиальный AMOLED-минимализм", "интерфейс и функции")
bullets(s, [
    ("Дизайн-язык: ", "Apple × Linear × AMOLED — чёрный фон, тонкие границы, спокойная типографика."),
    ("Профиль: ", "имя, @username, аватар с кропом, email, отпечаток ключа, устройства, recovery-пакет."),
    ("В чате: ", "статусы доставки/прочтения, «печатает…», «в сети», ответы, стикеры, разделители дат."),
    ("Доступность: ", "проверены узкие экраны 320 px и увеличенный шрифт — без переполнений."),
    ("PWA: ", "установка «на экран Домой», офлайн-кэш, Face ID-разблокировка на iPhone."),
], x=0.6, y=1.9, w=7.3, size=16.5, gap=12)
pic(s, "profile.png", 8.35, 1.75, 5.1)
pic(s, "conversation-online.png", 10.85, 1.75, 5.1)
footer(s, 9)
notes(s, "4:30–5:00. Показать профиль: отпечаток ключа и recovery — это не декор, а рабочие функции безопасности. Скриншот справа — статус «В сети». Одна фраза про доступность: тесты на 320 px и крупном шрифте.")

# ── 10. Что сделано самим: этапы ──────────────────────────────────────────
s = slide()
title(s, "Что сделано мной: этапы и проверки", "что сделано самим")
rows = [
    ("Этап по дорожной карте кейса", "Результат"),
    ("1 · Авторизация и профиль", "Google OAuth + пароль устройства, ошибки и валидация"),
    ("2 · Список чатов и диалог", "Поиск, избранное, история, разделители дат"),
    ("3 · Сообщения real-time", "Socket.IO + подписанный fetch, outbox без дублей"),
    ("4 · Фото и «прочитано»", "Шифрованные чанки; ACK после расшифровки и записи"),
    ("5 · Локальное хранение", "SQLCipher / шифрованный IndexedDB, офлайн-режим"),
    ("6 · Полировка и деплой", "E2EE, мультиустройство, staging, релизы с откатом"),
]
tbl = s.shapes.add_table(len(rows), 2, Inches(0.6), Inches(1.9), Inches(8.0), Inches(4.4)).table
tbl.columns[0].width = Inches(3.6); tbl.columns[1].width = Inches(4.4)
for i, (a, b) in enumerate(rows):
    for j, val in enumerate((a, b)):
        c = tbl.cell(i, j)
        c.fill.solid(); c.fill.fore_color.rgb = SURFACE if i else VIOLET
        c.margin_left = Inches(0.12); c.margin_right = Inches(0.1)
        c.margin_top = Inches(0.05); c.margin_bottom = Inches(0.05)
        p = c.text_frame.paragraphs[0]
        run(p, val, 14 if i else 14.5, TEXT if i else BLACK, bool(i == 0))
card(s, 8.85, 1.9, 3.85, 4.4, "Проверено", [
    "Flutter: 141/141 тестов PASS", "Сервер: 110/110 тестов PASS",
    "Браузерный QA: Edge + WebKit,", "HTTPS/WSS, офлайн, ACK",
    "Живые устройства: Samsung A31", "и iPhone тестера (Face ID)",
    "Крипто-interop v1↔v2 тестом"], accent=GREEN)
footer(s, 10)
notes(s, "5:00–5:40. Таблица слева — это дорожная карта кейса, пройденная полностью. Справа — доказательства: тесты и живые устройства. Подчеркнуть: школьник защищает сам, код его, понимание его. Цифры тестов — прогон 19.11, staging-линия.")

# ── 11. Демонстрация ──────────────────────────────────────────────────────
s = slide()
title(s, "Демонстрация: видео 1 мин 40 с на живом staging", "демонстрация")
bullets(s, [
    ("Вход на iPhone: ", "Google + Face ID-разблокировка ключей."),
    ("Сообщение Android → iPhone: ", "мгновенная доставка, ответ, галочки «доставлено/прочитано»."),
    ("Фото: ", "шифруется на устройстве, сервер видит только блобы."),
    ("Офлайн: ", "авиарежим → история читается → очередь доставляется после возврата сети."),
    ("Профиль и перезагрузка: ", "отпечаток ключа, recovery; ключи и история переживают перезапуск."),
], y=1.95, size=18, gap=14)
card(s, 0.6, 5.5, 12.1, 1.3, "Как смотреть", [
    "Видео shade-demo.mp4 (1:40) записывается по сценарию и вставляется в этот слайд. Запасной план — живое демо на alpha.shadechat.ru"], accent=GREEN)
footer(s, 11)
notes(s, "5:40–6:10. Запустить видео (1:40). Пока идёт — молчать, дать посмотреть. Если видео не запустилось: открыть alpha.shadechat.ru вживую и пройти шаги 1–4 сценария. Сценарий и запасной план — docs/hackathon/DEMO_VIDEO_SCRIPT.md.")

# ── 12. Улучшения ─────────────────────────────────────────────────────────
s = slide()
title(s, "Куда развиваю проект дальше", "улучшения")
bullets(s, [
    ("Forward secrecy: ", "Double Ratchet — чтобы украденный завтра ключ не открыл вчерашнюю переписку."),
    ("Перенос истории между устройствами ", "(history.transfer) и recovery-сессия для PRF-vault — блокер открытой беты."),
    ("Android на протокол v2: ", "криптографический interop уже покрыт тестом, осталась интеграция транспорта."),
    ("Групповые чаты ", "(sender-keys) и видеозвонки через Jitsi-ссылку — бонусные опции ТЗ."),
    ("Открытая бета: ", "после recovery и физических QA — приглашения для всех желающих."),
], y=1.95, size=18, gap=14)
tb, tf = box(s, 0.6, 5.7, 12.1, 0.9)
run(tf.paragraphs[0], "Проект живёт после хакатона: есть staging, реальные тестеры и план релизов.", 18, VIOLET, True)
footer(s, 12)
notes(s, "6:10–6:35. Показать, что понимаю пределы текущего решения и знаю, как их закрыть. Порядок не случайный: сначала безопасность и надёжность (recovery, PFS), потом фичи (группы, звонки).")

# ── 13. Чему научился / финал ─────────────────────────────────────────────
s = slide()
title(s, "Чему я научился", "выводы")
bullets(s, [
    ("Мессенджер — это протокол: ", "идемпотентность, подписи, очереди, версионирование, атомарные записи — а не «нарисовать чатик»."),
    ("Криптография собирается из стандартных примитивов, ", "если понимать, какое свойство даёт каждый: GCM — целостность, PSS — авторство, OAEP — конверт."),
    ("Тесты должны проверять реальность, а не моки: ", "настоящий HTTPS, два профиля, «враждебный» режим — иначе тест врёт."),
    ("Честность — инженерное качество: ", "«это не сделано, вот план» сильнее, чем натянутое «всё готово»."),
], y=1.95, size=18, gap=14)
tb, tf = box(s, 0.6, 5.55, 12.1, 1.3)
p = tf.paragraphs[0]; p.space_after = Pt(6)
run(p, "Спасибо! Готов ответить на вопросы.", 22, TEXT, True)
p = tf.add_paragraph()
run(p, "Код: github.com/kait1x/shade · Демо: alpha.shadechat.ru · README и материалы защиты — в репозитории", 15, SECOND)
footer(s, 13)
notes(s, "6:35–7:00. Финал своими словами, без чтения. Закончить приглашением к вопросам. Вопросы жюри — по шпаргалке DEFENSE_QA.md; отвечать спокойно, при незнании — честно «следующий этап, вот как решу».")

prs.save(OUT)
print("saved", OUT, "slides:", len(prs.slides._sldIdLst))