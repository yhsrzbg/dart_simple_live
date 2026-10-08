import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'qr_login_controller.dart';

class DouyuQRLoginPage extends GetView<DouyuQRLoginController> {
  const DouyuQRLoginPage({super.key});
  @override
  Widget build(BuildContext context) => AppScaffold(
          child: Column(children: [
        AppStyle.vGap32,
        Row(children: [
          AppStyle.hGap48,
          HighlightButton(
              focusNode: controller.backFocusNode,
              iconData: Icons.arrow_back,
              text: '返回',
              autofocus: true,
              onTap: () => Get.back()),
          AppStyle.hGap32,
          Text('登录斗鱼',
              style: AppStyle.titleStyleWhite
                  .copyWith(fontSize: 36.w, fontWeight: FontWeight.bold)),
        ]),
        Expanded(child: Center(child: Obx(() {
          final status = controller.qrStatus.value;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            if (status == DouyuQRStatus.loading)
              const CircularProgressIndicator(color: Colors.white)
            else if (status == DouyuQRStatus.waiting ||
                status == DouyuQRStatus.scanned)
              QrImageView(
                  data: controller.qrcodeUrl.value,
                  backgroundColor: Colors.white,
                  size: 360.w),
            AppStyle.vGap24,
            Text(
                status == DouyuQRStatus.expired
                    ? '二维码已失效，请刷新'
                    : status == DouyuQRStatus.failed
                        ? '登录失败，请刷新重试'
                        : status == DouyuQRStatus.scanned
                            ? '已扫描，请在手机上确认登录'
                            : '请使用斗鱼 App 扫码并确认登录',
                style: AppStyle.textStyleWhite),
            AppStyle.vGap24,
            HighlightButton(
                focusNode: controller.refreshFocusNode,
                iconData: Icons.refresh,
                text: '刷新二维码',
                onTap: controller.loadQRCode),
          ]);
        }))),
      ]));
}
