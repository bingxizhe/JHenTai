
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';

enum _DialogPhase { scanning, reviewing, deleting, completed }

class EHDeleteHistoryVersionsDialog extends StatefulWidget {
  const EHDeleteHistoryVersionsDialog({Key? key}) : super(key: key);

  @override
  State<EHDeleteHistoryVersionsDialog> createState() => _EHDeleteHistoryVersionsDialogState();
}

class _EHDeleteHistoryVersionsDialogState extends State<EHDeleteHistoryVersionsDialog> {
  _DialogPhase phase = _DialogPhase.scanning;

  /// title -> sorted gallerys (newest first by publishTime)
  Map<String, List<GalleryDownloadedData>> groupedGallerys = {};

  /// gids selected for deletion
  Set<int> selectedGids = {};

  /// expanded group titles
  Set<String> expandedTitles = {};

  /// deletion progress
  int deleteTotal = 0;
  int deleteCurrent = 0;
  int deleteSuccess = 0;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    await Future.delayed(Duration.zero);

    try {
      List<GalleryDownloadedData> allGallerys = List.of(galleryDownloadService.gallerys);

      Map<String, List<GalleryDownloadedData>> grouped = groupBy(
        allGallerys,
        (GalleryDownloadedData g) => g.title,
      );

      grouped.removeWhere((title, list) => list.length <= 1);

      grouped.forEach((title, list) {
        list.sort((a, b) => b.publishTime.compareTo(a.publishTime));
      });

      Set<int> defaultSelected = {};
      grouped.forEach((title, list) {
        for (int i = 1; i < list.length; i++) {
          defaultSelected.add(list[i].gid);
        }
      });

      if (!mounted) {
        return;
      }
      setState(() {
        groupedGallerys = grouped;
        selectedGids = defaultSelected;
        phase = _DialogPhase.reviewing;
      });
    } catch (e) {
      log.error('scan history versions failed', e);
      if (mounted) {
        toast('scanFailed'.tr);
        backRoute();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('deleteHistoryVersions'.tr),
      content: SizedBox(
        width: 480,
        height: 520,
        child: _buildContent(),
      ),
      actions: _buildActions(),
      actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
    );
  }

  Widget _buildContent() {
    switch (phase) {
      case _DialogPhase.scanning:
        return _buildScanning();
      case _DialogPhase.reviewing:
        return _buildReviewing();
      case _DialogPhase.deleting:
        return _buildDeleting();
      case _DialogPhase.completed:
        return _buildCompleted();
    }
  }

  Widget _buildScanning() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('scanningHistoryVersions'.tr),
        ],
      ),
    );
  }

  Widget _buildReviewing() {
    if (groupedGallerys.isEmpty) {
      return Center(child: Text('noHistoryVersionsToDelete'.tr));
    }

    return Column(
      children: [
        _buildSelectAllBar(),
        const Divider(height: 1),
        Expanded(child: _buildGroupList()),
      ],
    );
  }

  Widget _buildSelectAllBar() {
    bool allSelected = _allSelectableGids.every((gid) => selectedGids.contains(gid));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: allSelected,
            onChanged: (_) => _toggleAll(),
          ),
          GestureDetector(
            onTap: _toggleAll,
            child: Text(
              allSelected ? 'deselectAll'.tr : 'selectAll'.tr,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const Spacer(),
          Text(
            '${'selected'.tr}: ${selectedGids.length}',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupList() {
    List<String> titles = groupedGallerys.keys.toList()..sort();

    return ListView.builder(
      itemCount: titles.length,
      itemBuilder: (context, index) {
        String title = titles[index];
        List<GalleryDownloadedData> gallerys = groupedGallerys[title]!;

        return ExpansionTile(
          key: ValueKey(title),
          initiallyExpanded: expandedTitles.contains(title),
          onExpansionChanged: (expanded) {
            setState(() {
              if (expanded) {
                expandedTitles.add(title);
              } else {
                expandedTitles.remove(title);
              }
            });
          },
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(
            '${gallerys.length} ${'items'.tr} · ${'selected'.tr}: ${gallerys.where((g) => selectedGids.contains(g.gid)).length}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          children: gallerys.map((g) => _buildGalleryItem(g, isFirst: g == gallerys.first)).toList(),
        );
      },
    );
  }

  Widget _buildGalleryItem(GalleryDownloadedData gallery, {required bool isFirst}) {
    bool isSelected = selectedGids.contains(gallery.gid);
    return CheckboxListTile(
      dense: true,
      value: isSelected,
      onChanged: (v) {
        setState(() {
          if (v == true) {
            selectedGids.add(gallery.gid);
          } else {
            selectedGids.remove(gallery.gid);
          }
        });
      },
      title: Row(
        children: [
          if (isFirst)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'newest'.tr,
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          Expanded(
            child: Text(
              gallery.publishTime,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${gallery.pageCount} ${'pages'.tr}',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildDeleting() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              value: deleteTotal > 0 ? deleteCurrent / deleteTotal : null,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '$deleteCurrent / $deleteTotal',
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'deletingHistoryVersions'.tr,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompleted() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            '${'deleteHistoryVersionsCompleted'.tr}\n($deleteSuccess / $deleteTotal)',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions() {
    switch (phase) {
      case _DialogPhase.scanning:
        return [
          TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        ];
      case _DialogPhase.reviewing:
        bool canConfirm = selectedGids.isNotEmpty && expandedTitles.isNotEmpty;
        return [
          TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
          TextButton(
            onPressed: canConfirm ? _executeDeletion : null,
            child: Text('confirm'.tr),
          ),
        ];
      case _DialogPhase.deleting:
        return [];
      case _DialogPhase.completed:
        return [
          TextButton(onPressed: () => backRoute(result: true), child: Text('OK'.tr)),
        ];
    }
  }

  List<int> get _allSelectableGids {
    return groupedGallerys.values.expand((list) => list).map((g) => g.gid).toList();
  }

  void _toggleAll() {
    setState(() {
      bool allSelected = _allSelectableGids.every((gid) => selectedGids.contains(gid));
      if (allSelected) {
        selectedGids.clear();
      } else {
        selectedGids = Set.from(_allSelectableGids);
      }
    });
  }

  Future<void> _executeDeletion() async {
    List<GalleryDownloadedData> toDelete = groupedGallerys.values
        .expand((list) => list)
        .where((g) => selectedGids.contains(g.gid))
        .toList();

    setState(() {
      phase = _DialogPhase.deleting;
      deleteTotal = toDelete.length;
      deleteCurrent = 0;
      deleteSuccess = 0;
    });

    for (int i = 0; i < toDelete.length; i++) {
      try {
        await galleryDownloadService.deleteGallery(toDelete[i], deleteImages: true);
        deleteSuccess++;
      } catch (e) {
        log.error('delete history version failed: ${toDelete[i].gid}', e);
      }
      deleteCurrent = i + 1;
      if (mounted) {
        setState(() {});
      }
    }

    if (mounted) {
      setState(() => phase = _DialogPhase.completed);
    }
  }
}
