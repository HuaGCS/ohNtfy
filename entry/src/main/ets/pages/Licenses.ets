import { router } from '@kit.ArkUI';

@Entry
@Component
struct Licenses {
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

        Text($r('app.string.licenses_title'))
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
          // ── HarmonyOS SDK ──
          LicenseBlock({
            name: 'HarmonyOS SDK',
            version: 'API 24',
            license: 'Proprietary',
            notice: 'Copyright © Huawei Device Co., Ltd. All rights reserved.\n\n'
              + 'This application uses the HarmonyOS Software Development Kit (SDK) '
              + 'under the terms of the Huawei HarmonyOS SDK License Agreement.'
          });

          // ── ntfy ──
          LicenseBlock({
            name: 'ntfy',
            version: 'v2.x',
            license: 'Apache License 2.0',
            notice: 'Copyright 2023 Philipp C. Heckel\n\n'
              + 'Licensed under the Apache License, Version 2.0 (the "License"); '
              + 'you may not use this file except in compliance with the License. '
              + 'You may obtain a copy of the License at\n\n'
              + '    http://www.apache.org/licenses/LICENSE-2.0\n\n'
              + 'Unless required by applicable law or agreed to in writing, software '
              + 'distributed under the License is distributed on an "AS IS" BASIS, '
              + 'WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. '
              + 'See the License for the specific language governing permissions and '
              + 'limitations under the License.\n\n'
              + 'This application is an unofficial third-party client for the ntfy service. '
              + 'The ntfy protocol and API are used under fair use. '
              + 'For more information, visit: https://ntfy.sh'
          });

          // ── Acknowledgements ──
          Column() {
            Text('Acknowledgements')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ bottom: 8 });

            Text('This application was built using the HarmonyOS ecosystem. '
              + 'Special thanks to the open source community and all contributors '
              + 'who make software development possible.')
              .fontSize(14)
              .fontColor('#FF444444')
              .lineHeight(22);
          }
          .width('100%')
          .padding(16)
          .margin({ top: 4, left: 8, right: 8 });

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
struct LicenseBlock {
  @Prop name: string = '';
  @Prop version: string = '';
  @Prop license: string = '';
  @Prop notice: string = '';

  build() {
    Column() {
      Row() {
        Text(this.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium);

        Blank();

        Text(this.license)
          .fontSize(12)
          .fontColor('#FF0078D4')
          .backgroundColor('#FFE8F4FF')
          .borderRadius(4)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 });
      }
      .width('100%');

      if (this.version !== '') {
        Text('Version: ' + this.version)
          .fontSize(12)
          .fontColor('#FF999999')
          .width('100%')
          .margin({ top: 4 });
      }

      Text(this.notice)
        .fontSize(13)
        .fontColor('#FF555555')
        .lineHeight(20)
        .width('100%')
        .margin({ top: 8 });
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFF8F8F8')
    .borderRadius(12)
    .margin({ top: 12, left: 16, right: 16 });
  }
}
