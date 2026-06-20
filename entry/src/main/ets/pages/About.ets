import { router } from '@kit.ArkUI';

@Entry
@Component
struct About {
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

        Text($r('app.string.about'))
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
          // App icon & name
          Column() {
            Image($r('app.media.app_icon'))
              .width(72)
              .height(72)
              .borderRadius(16);

            Text($r('app.string.app_name'))
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 12 });

            Text($r('app.string.app_description'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 4 });
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 40 });

          // Info cards
          Column() {
            AboutRow({ label: $r('app.string.version'), value: $r('app.string.version_name') });
            AboutRow({ label: $r('app.string.sdk'), value: 'HarmonyOS 6.1.0 (API 24)' });
            AboutRow({ label: $r('app.string.architecture'), value: $r('app.string.architecture_value') });
          }
          .width('100%')
          .backgroundColor($r('app.color.card_secondary_bg'))
          .borderRadius(12)
          .margin({ top: 32, left: 16, right: 16 });

          // Description
          Column() {
            Text($r('app.string.what_is_ntfy'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ bottom: 8 });

            Text($r('app.string.ntfy_description'))
              .fontSize(14)
              .fontColor($r('app.color.text_body'))
              .lineHeight(22);

            Text($r('app.string.ntfy_source'))
              .fontSize(13)
              .fontColor($r('app.color.accent_color'))
              .margin({ top: 12 });
          }
          .width('100%')
          .padding(16)
          .margin({ top: 16, left: 16, right: 16 });

          // Disclaimer
          Column() {
            Text($r('app.string.disclaimer_label'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ bottom: 8 });

            Text($r('app.string.disclaimer_text'))
              .fontSize(13)
              .fontColor($r('app.color.text_muted'))
              .lineHeight(20);
          }
          .width('100%')
          .padding(16)
          .margin({ top: 16, left: 16, right: 16 });

          // Source code link
          Row() {
            Text($r('app.string.source_code'))
              .fontSize(14)
              .fontColor($r('app.color.accent_color'));
            Blank();
            Image($r('app.media.ic_chevron'))
              .width(16)
              .height(16);
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .margin({ top: 16, left: 16, right: 16 })
          .backgroundColor($r('app.color.card_secondary_bg'))
          .borderRadius(12);

          Column().height(60);
        }
        .width('100%');
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'));
  }
}

@Component
struct AboutRow {
  label: ResourceStr = '';
  value: ResourceStr = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'));
      Blank();
      Text(this.value)
        .fontSize(14)
        .fontColor($r('app.color.text_hint'));
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(0);
  }
}
