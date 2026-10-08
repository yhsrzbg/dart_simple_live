import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ns_danmaku/models/danmaku_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';
import 'douyu_playback_recovery.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;
  List<DouyuStream> _douyuStreams = [];
  final _douyuRecovery = DouyuPlaybackRecovery();
  Worker? _douyuAccountWorker;
  StreamSubscription<Duration>? _douyuPositionSubscription;
  int _playRequest = 0;
  int _roomLoad = 0;
  int _qualityRequest = 0;
  bool _switchingRoom = false;
  bool _roomClosed = false;
  bool _douyuReplacing = false;
  bool _douyuOpening = false;
  bool _douyuOpenFailed = false;
  int _douyuTerminalTicket = -1;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 是否处于后台
  var isBackground = false;

  var datetime = "00:00".obs;

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;

  @override
  void onInit() {
    initTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");

    loadData();

    super.onInit();
    if (Get.isRegistered<DouyuAccountService>()) {
      _douyuAccountWorker =
          ever(DouyuAccountService.instance.revision, (_) async {
        if (site.id != 'douyu' || _roomClosed) return;
        final ticket = ++_playRequest;
        ++_qualityRequest;
        _douyuRecovery.invalidate();
        _douyuReplacing = true;
        playUrls.clear();
        _douyuStreams.clear();
        await player.stop();
        if (ticket != _playRequest || _roomClosed || site.id != 'douyu') return;
        if (!_roomClosed && currentQuality >= 0 && detail.value != null) {
          await getPlayUrl();
        } else if (detail.value != null) {
          getPlayQualites();
        } else {
          _douyuReplacing = false;
        }
      });
    }
    _douyuPositionSubscription = player.stream.position.listen((position) {
      if (site.id == 'douyu') {
        _douyuRecovery.observeProgress(position,
            playing: player.state.playing,
            buffering: player.state.buffering,
            now: DateTime.now());
      }
    });
  }

  void refreshRoom() {
    //messages.clear();

    liveDanmaku.stop();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  /// 加载直播间信息
  void loadData() async {
    final ticket = ++_roomLoad;
    ++_playRequest;
    ++_qualityRequest;
    _douyuRecovery.invalidate();
    final snapshotSite = site;
    final snapshotRoom = roomId;
    try {
      SmartDialog.showLoading(msg: "");
      pageLoadding.value = true;
      final result =
          await snapshotSite.liveSite.getRoomDetail(roomId: snapshotRoom);
      if (_roomClosed || ticket != _roomLoad) return;
      detail.value = result;

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
    } catch (e) {
      if (!_roomClosed && ticket == _roomLoad) {
        SmartDialog.showToast(e.toString());
      }
    } finally {
      if (ticket == _roomLoad && !_roomClosed) {
        SmartDialog.dismiss(status: SmartStatus.loading);
        pageLoadding.value = false;
      }
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    if (_roomClosed || detail.value == null) return;
    final ticket = ++_qualityRequest;
    final snapshotSite = site;
    final snapshotDetail = detail.value!;
    qualites.clear();
    currentQuality = -1;
    try {
      var playQualites =
          await snapshotSite.liveSite.getPlayQualites(detail: snapshotDetail);
      if (_roomClosed ||
          ticket != _qualityRequest ||
          snapshotDetail != detail.value ||
          snapshotSite != site) return;

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      if (_roomClosed || ticket != _qualityRequest) return;
      _douyuReplacing = false;
      if (site.id != 'douyu') Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<void> getPlayUrl({int line = 0}) async {
    if (_roomClosed ||
        detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) return;
    final ticket = ++_playRequest;
    final roomDetail = detail.value!;
    final quality = qualites[currentQuality];
    _douyuRecovery.invalidate();
    _douyuReplacing = site.id == 'douyu';
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    try {
      var playUrl =
          await site.liveSite.getPlayUrls(detail: roomDetail, quality: quality);
      if (_roomClosed || ticket != _playRequest) return;
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        return;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      _douyuStreams = playUrl is DouyuPlayUrl ? playUrl.streams : [];
      currentLineIndex = line % playUrl.urls.length;
      _showDouyuQuality();
      currentLineInfo.value = "线路${currentLineIndex + 1}";
      //重置错误次数
      mediaErrorRetryCount = 0;
      await setPlayer();
    } catch (_) {
      if (!_roomClosed && ticket == _playRequest) {
        errorMsg.value =
            site.id == 'douyu' ? '斗鱼取流失败，请刷新或在设置中重新登录' : '无法读取播放地址';
        SmartDialog.showToast(errorMsg.value);
      }
    } finally {
      if (ticket == _playRequest) _douyuReplacing = false;
    }
  }

  void _showDouyuQuality() {
    if (_douyuStreams.isEmpty ||
        currentLineIndex < 0 ||
        currentLineIndex >= _douyuStreams.length) return;
    final stream = _douyuStreams[currentLineIndex];
    currentQualityInfo.value = stream.actualQuality;
    if (stream.downgraded) {
      SmartDialog.showToast('斗鱼实际返回${stream.actualQuality}，可在设置→账号中扫码登录或重新登录');
    }
  }

  void changePlayLine(int index) {
    if (site.id == 'douyu') {
      getPlayUrl(line: index);
      return;
    }
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<void> setPlayer() async {
    if (_roomClosed ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    await player.open(
      Media(
        playUrls[currentLineIndex],
        httpHeaders: playHeaders,
      ),
    );

    if (site.id == 'douyu') {
      Log.d('斗鱼播放：${currentLineInfo.value}，${currentQualityInfo.value}');
    } else if (currentLineIndex >= 0 && currentLineIndex < playUrls.length) {
      Log.d("播放链接\r\n：${playUrls[currentLineIndex]}");
    }
  }

  @override
  String formatPlayerLog(String message) => site.id == 'douyu'
      ? message.replaceAll(RegExp(r'https?://\S+|/live/\S+'), '<斗鱼授权地址>')
      : message;

  Future<void> _recoverDouyu() async {
    if (_douyuTerminalTicket == _playRequest) return;
    if (_roomClosed ||
        _douyuReplacing ||
        detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) return;
    if (_douyuRecovery.running) {
      if (_douyuOpening) _douyuOpenFailed = true;
      return;
    }
    final roomDetail = detail.value!;
    final quality = qualites[currentQuality];
    final previousLine = currentLineIndex < 0 ? 0 : currentLineIndex;
    final recoveryTicket = _playRequest;
    final result = await _douyuRecovery.recover((attempt, isCurrent) async {
      final urls =
          await site.liveSite.getPlayUrls(detail: roomDetail, quality: quality);
      if (!isCurrent() || urls.urls.isEmpty) return false;
      playUrls.value = urls.urls;
      playHeaders = urls.headers;
      _douyuStreams = urls is DouyuPlayUrl ? urls.streams : [];
      currentLineIndex = (previousLine + (attempt - 1)) % urls.urls.length;
      _showDouyuQuality();
      _douyuOpening = true;
      _douyuOpenFailed = false;
      try {
        await setPlayer();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return isCurrent() && !_douyuOpenFailed;
      } finally {
        _douyuOpening = false;
      }
    });
    if (result == DouyuRecoveryResult.exhausted &&
        !_roomClosed &&
        recoveryTicket == _playRequest) {
      final ticket = _playRequest;
      _douyuTerminalTicket = ticket;
      try {
        final latest =
            await site.liveSite.getRoomDetail(roomId: roomDetail.roomId);
        if (ticket != _playRequest || _roomClosed) return;
        if (!latest.status && !latest.isRecord) {
          liveStatus.value = false;
          return;
        }
      } catch (_) {}
      if (ticket == _playRequest && !_roomClosed) {
        errorMsg.value = '斗鱼播放中断，请刷新或重新登录';
      }
    }
  }

  @override
  void mediaEnd() async {
    if (_roomClosed || _switchingRoom) return;
    if (site.id == 'douyu') {
      await _recoverDouyu();
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
    } else {
      changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    if (_roomClosed || _switchingRoom) return;
    if (site.id == 'douyu') {
      await _recoverDouyu();
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) return;
    final ticket = ++_roomLoad;
    ++_playRequest;
    ++_qualityRequest;
    _switchingRoom = true;
    _douyuRecovery.invalidate();
    _douyuStreams.clear();
    detail.value = null;
    currentQuality = -1;
    qualites.clear();
    playUrls.clear();

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();
    if (_roomClosed || ticket != _roomLoad) return;
    _switchingRoom = false;

    // 刷新信息
    loadData();
  }

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index += 1;
    if (index >= liveChannels.length) {
      index = 0;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index -= 1;
    if (index < 0) {
      index = liveChannels.length - 1;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  @override
  void onClose() {
    _roomClosed = true;
    ++_roomLoad;
    ++_qualityRequest;
    ++_playRequest;
    _douyuRecovery.close();
    _douyuAccountWorker?.dispose();
    _douyuPositionSubscription?.cancel();
    liveDanmaku.stop();

    danmakuController = null;
    super.onClose();
  }
}
