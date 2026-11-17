import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'repository.dart';
import 'vinyl.dart';
import 'aluminium.dart';

class StickerCollection extends StatefulWidget {
  final String username;
  final bool owner;
  // Transport seam: native callers pass the v1 repository and its reconnect
  // stream; the web alpha injects its own adapter. No platform services are
  // read here, so the whole widget compiles for Flutter web.
  final StickerBackend backend;
  final Stream<bool>? reloadStream;
  const StickerCollection(
      {super.key,
      required this.username,
      required this.owner,
      required this.backend,
      this.reloadStream});
  @override
  State<StickerCollection> createState() => _CollectionState();
}

class _CollectionState extends State<StickerCollection> {
  Collection? data;
  List<Placement> wall = [];
  bool book = false, editing = false, busy = false;
  String? error, selected;
  StreamSubscription<bool>? reconnect;
  int page = 0;
  double baseScale = 1, baseRotation = 0;
  @override
  void initState() {
    super.initState();
    reconnect = widget.reloadStream?.listen((online) {
      if (online && !busy && !editing && mounted) load();
    });
    load();
  }

  @override
  void dispose() {
    reconnect?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final d = await widget.backend.load(widget.username, widget.owner);
      if (mounted) {
        setState(() {
          data = d;
          wall = d.wall;
          editing = false;
          selected = null;
          page = 0;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.backend.save(data!.revision, wall);
      if (mounted) {
        setState(() {
          data = Collection({
            ...result,
            'inventory': [
              for (final g in data!.gifts)
                {
                  'giftId': g.id,
                  'stickerId': g.art,
                  'note': g.note,
                  'fromUsername': g.from
                }
            ]
          });
          wall = data!.wall;
          editing = false;
          selected = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void inspect(Gift g) => showDialog(
      context: context,
      builder: (_) => VinylViewer(g.art, from: g.from, note: g.note));
  void startEdit() {
    setState(() {
      wall = [for (final p in data!.wall) Placement.parse(p.json(0))];
      editing = true;
      book = false;
    });
  }

  void add(Gift g) {
    if (wall.length >= 32 || wall.any((p) => p.id == g.id)) return;
    setState(() {
      wall.add(Placement(g.id));
      selected = g.id;
    });
  }

  @override
  Widget build(BuildContext ctx) {
    final gifts = data?.gifts ?? [];
    return Padding(
        padding: const EdgeInsets.only(top: 20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: Text('Подарки',
                    style: Theme.of(ctx).textTheme.titleMedium)),
            if (!widget.owner)
              TextButton.icon(
                  onPressed: () async {
                    final sent = await showDialog<bool>(
                        context: ctx,
                        builder: (_) => GiftDialog(widget.username,
                            backend: widget.backend));
                    if (sent == true && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Подарок отправлен')));
                      load();
                    }
                  },
                  icon: const Icon(Icons.card_giftcard),
                  label: const Text('Подарить'))
          ]),
          if (!editing)
            Wrap(spacing: 6, children: [
              ChoiceChip(
                  label: const Text('Стена'),
                  selected: !book,
                  onSelected: (_) => setState(() => book = false)),
              ChoiceChip(
                  label: const Text('Книжка'),
                  selected: book,
                  onSelected: (_) => setState(() => book = true)),
              if (!busy)
                IconButton(
                    tooltip: 'Обновить подарки',
                    icon: const Icon(Icons.refresh),
                    onPressed: load)
            ]),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.redAccent)),
          if (busy) const LinearProgressIndicator(),
          if (data != null) ...[
            if (book)
              _book(gifts)
            else
              LayoutBuilder(builder: (ctx, b) {
                final w = b.maxWidth, h = w * .69, side = w * .23;
                // The saved wall can reference a gift the inventory list does
                // not contain (partial load, server-side cleanup); skip such
                // placements instead of crashing the whole collection.
                final giftsById = {for (final g in gifts) g.id: g};
                return Container(
                    height: h,
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black38,
                              blurRadius: 16,
                              offset: Offset(0, 6))
                        ]),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(children: [
                      const Positioned.fill(child: ReferenceLid()),
                      for (final p in wall)
                        if (giftsById[p.id] != null)
                        Positioned(
                            key: ValueKey(p.id),
                            left: p.x * (w - side),
                            top: p.y * (h - side),
                            width: side,
                            height: side,
                            child: Transform.rotate(
                                angle: p.rotation,
                                child: Transform.scale(
                                    scale: p.scale,
                                    child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {
                                          if (editing) {
                                            setState(() => selected = p.id);
                                          } else {
                                            final g = giftsById[p.id];
                                            if (g != null) inspect(g);
                                          }
                                        },
                                        onScaleStart: editing && !busy
                                            ? (d) {
                                                baseScale = p.scale;
                                                baseRotation = p.rotation;
                                                setState(() {
                                                  wall.remove(p);
                                                  wall.add(p);
                                                  selected = p.id;
                                                });
                                              }
                                            : null,
                                        onScaleUpdate: editing && !busy
                                            ? (d) => setState(() {
                                                  p.x = (p.x +
                                                          d.focalPointDelta.dx /
                                                              (w - side))
                                                      .clamp(0, 1);
                                                  p.y = (p.y +
                                                          d.focalPointDelta.dy /
                                                              (h - side))
                                                      .clamp(0, 1);
                                                  p.scale =
                                                      (baseScale * d.scale)
                                                          .clamp(.5, 2);
                                                  p.rotation = math.atan2(
                                                      math.sin(baseRotation +
                                                          d.rotation),
                                                      math.cos(baseRotation +
                                                          d.rotation));
                                                })
                                            : null,
                                        child: DecoratedBox(
                                            decoration: BoxDecoration(
                                                border:
                                                    selected == p.id && editing
                                                        ? Border.all(
                                                            color: Colors.amber,
                                                            width: 2)
                                                        : null),
                                            child: stamp(
                                                giftsById[p.id]!.art))))))
                    ]));
              }),
            if (widget.owner && !book)
              Wrap(spacing: 8, children: [
                TextButton.icon(
                    icon: Icon(editing ? Icons.check : Icons.tune, size: 16),
                    onPressed: busy
                        ? null
                        : editing
                            ? save
                            : startEdit,
                    label: Text(editing ? 'Готово' : 'Оформить')),
                if (editing) ...[
                  TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              setState(() {
                                wall = data!.wall;
                                editing = false;
                                error = null;
                                selected = null;
                              });
                            },
                      child: const Text('Отмена')),
                  if (selected != null)
                    TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                  wall.removeWhere((v) => v.id == selected);
                                  selected = null;
                                }),
                        child: const Text('Снять'))
                ]
              ]),
            if (editing)
              SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final g
                        in gifts.where((g) => !wall.any((p) => p.id == g.id)))
                      InkWell(
                          onTap: busy ? null : () => add(g),
                          child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: stamp(g.art)))
                  ]))
          ]
        ]));
  }

  Future<void> inspectGroup(List<Gift> gifts) async {
    if (!widget.owner || gifts.length == 1) {
      inspect(gifts.first);
      return;
    }
    final chosen = await showModalBottomSheet<Gift>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
            child: ListView.builder(
                shrinkWrap: true,
                itemCount: gifts.length,
                itemBuilder: (_, i) => ListTile(
                    leading: stamp(gifts[i].art, size: 40),
                    title: Text('от @${gifts[i].from}'),
                    subtitle: Text(gifts[i].note ?? ''),
                    onTap: () => Navigator.pop(ctx, gifts[i])))));
    if (mounted && chosen != null) inspect(chosen);
  }

  Widget _book(List<Gift> gifts) {
    final groups = <String, List<Gift>>{};
    for (final g in gifts) {
      groups.putIfAbsent(g.art, () => []).add(g);
    }
    final entries = groups.entries.toList();
    if (entries.isEmpty) {
      return const Padding(
          padding: EdgeInsets.all(24),
          child: Text('В книжке пока нет наклеек'));
    }
    final pages = (entries.length / 2).ceil();
    return Column(children: [
      SizedBox(
          height: 140 + MediaQuery.textScalerOf(context).scale(66),
          child: PageView.builder(
              itemCount: pages,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (ctx, i) => Row(children: [
                    for (final e in entries.skip(i * 2).take(2))
                      Expanded(
                          child: Card(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18)),
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    InkWell(
                                        onTap: () => inspectGroup(e.value),
                                        child: stamp(e.key)),
                                    Text(stickerNames[e.key] ?? ''),
                                    Text('×${e.value.length}'),
                                    if (widget.owner)
                                      TextButton(
                                          onPressed: wall.length >= 32 ||
                                                  e.value.every((g) => wall
                                                      .any((p) => p.id == g.id))
                                              ? null
                                              : () {
                                                  final available = e.value
                                                      .where((g) => !wall.any(
                                                          (p) => p.id == g.id));
                                                  if (available.isEmpty) return;
                                                  startEdit();
                                                  add(available.first);
                                                },
                                          child: const Text('Наклеить на стену',
                                              textAlign: TextAlign.center))
                                  ])))
                  ]))),
      Text('${page + 1} / $pages')
    ]);
  }
}

class GiftDialog extends StatefulWidget {
  final String to;
  final StickerBackend backend;
  const GiftDialog(this.to, {super.key, required this.backend});
  @override
  State<GiftDialog> createState() => _GiftDialogState();
}

class _GiftDialogState extends State<GiftDialog> {
  String art = 'flowers', note = '', request = '', error = '';
  bool busy = false;
  Future<void> send() async {
    if (busy) return;
    if (request.isEmpty) {
      final r = math.Random.secure();
      request = List.generate(
          16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    }
    setState(() => busy = true);
    try {
      await widget.backend.gift(widget.to, art, note, request);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text('Подарок для @${widget.to}'),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            stamp(art, size: 110),
            Wrap(children: [
              for (final e in stickerNames.entries)
                ChoiceChip(
                    label: Text(e.value),
                    selected: e.key == art,
                    onSelected: busy
                        ? null
                        : (_) => setState(() {
                              art = e.key;
                              request = '';
                            }))
            ]),
            TextField(
                enabled: !busy,
                maxLength: 240,
                decoration: const InputDecoration(labelText: 'Личная записка'),
                onChanged: (v) {
                  note = v;
                  request = '';
                }),
            if (error.isNotEmpty)
              Text(error,
                  style: const TextStyle(color: Colors.redAccent))
          ])),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(c),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: busy ? null : send,
                child: Text(busy ? 'Отправка…' : 'Подарить'))
          ]);
}
