import { router } from '@kit.ArkUI';

@Entry
@Component
struct Privacy {
  build() {
    Column() {
      // Header
      Row() {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_back'))
            .width(20)
            .height(20);
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .margin({ left: 4 })
        .onClick(() => router.back());

        Text($r('app.string.privacy_policy_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 });

        Blank();
      }
      .width('100%')
      .height(56)
      .padding({ right: 16 });

      Scroll() {
        Column() {
          // ── Introduction ──
          SectionBlock({
            title: '数据收集说明',
            content: '本应用（NtfyPush）非常重视您的隐私。我们承诺不会收集、存储或上传任何您的个人身份信息。'
          });

          SectionBlock({
            title: '我们收集的数据',
            content: '本应用本身不收集任何个人数据。应用仅将以下数据存储在您的设备本地：\n\n'
              + '• 订阅的主题列表（服务器地址、主题名称、显示名称）\n'
              + '• 最近接收的消息缓存\n'
              + '• 应用设置（默认服务器、轮询间隔、通知偏好等）\n\n'
              + '以上所有数据仅保存在设备本地，不会传输到任何第三方服务器。'
          });

          SectionBlock({
            title: '第三方服务',
            content: '本应用是一个 ntfy 推送服务的客户端。您连接的 ntfy 服务器由您自行选择（默认为 ntfy.sh）。\n\n'
              + '当您使用 ntfy 服务时，您的消息会经过您指定的 ntfy 服务器中转。'
              + '请您自行了解所使用的 ntfy 服务器的隐私政策。\n\n'
              + 'ntfy.sh 的隐私政策请参考：https://ntfy.sh/privacy'
          });

          SectionBlock({
            title: '网络权限',
            content: '本应用需要网络访问权限以连接您指定的 ntfy 服务器，实现消息的收发功能。'
              + '网络请求仅在您订阅的主题范围内进行，不会用于其他用途。'
          });

          SectionBlock({
            title: '通知权限',
            content: '本应用需要通知权限以在收到新消息时向您推送通知。您可以随时在系统设置中关闭通知权限。'
          });

          SectionBlock({
            title: '后台运行',
            content: '本应用需要后台运行权限以确保能够持续接收推送消息。'
              + '后台运行时，应用仅保持必要的网络连接以接收消息更新，不会执行任何额外的数据收集操作。'
          });

          SectionBlock({
            title: '数据删除',
            content: '您可以随时通过以下方式删除本地数据：\n\n'
              + '• 删除单个订阅：在首页长按订阅 → 删除\n'
              + '• 清除所有数据：在系统设置中清除应用数据\n'
              + '• 卸载应用：将删除所有本地存储的数据'
          });

          SectionBlock({
            title: '政策更新',
            content: '本隐私政策可能会不时更新。如有重大变更，我们将在应用内通知您。'
              + '继续使用本应用即表示您同意本隐私政策的条款。'
          });

          SectionBlock({
            title: '联系方式',
            content: '如果您对本隐私政策有任何疑问或建议，请通过以下方式联系我们：\n\n'
              + '• Gitea 仓库 Issue：\n'
              + '  https://gitea.huagcs.com/OpenHarmony/ntfy/issues\n\n'
              + '• 在线版隐私政策：\n'
              + '  https://gitea.huagcs.com/OpenHarmony/ntfy/raw/branch/main/PRIVACY.md'
          });

          // Note about English version
          Column() {
            Text('English')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ bottom: 8 });

            Text('This privacy policy is also available in English for reference. '
              + 'In case of any discrepancy, the Chinese version shall prevail.\n\n'
              + 'Online version:\n'
              + 'https://gitea.huagcs.com/OpenHarmony/ntfy/raw/branch/main/PRIVACY.md')
              .fontSize(13)
              .fontColor('#FF888888')
              .lineHeight(20);
          }
          .width('100%')
          .padding(16);

          Column().height(40);
        }
        .width('100%');
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFFFF');
  }
}

@Component
struct SectionBlock {
  @Prop title: string = '';
  @Prop content: string = '';

  build() {
    Column() {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 8 });

      Text(this.content)
        .fontSize(14)
        .fontColor('#FF444444')
        .lineHeight(22);
    }
    .width('100%')
    .padding(16)
    .margin({ top: 4, left: 8, right: 8 });
  }
}
