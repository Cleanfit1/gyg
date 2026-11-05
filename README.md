# iPhone自用App：不含私人资料的云端构建版

这是开发阶段的原生iOS源码，用于验证Windows用户通过云端macOS编译，再自行签名安装的路径。它不包含本地聊天模型，暂时无法生成AI回复，不是已完成的聊天产品。

## 上传范围

此目录只保留通用Swift代码、测试、XcodeGen配置和手动构建工作流。
已移除照片、历史聊天、语音、语料统计、个人种子记忆、姓名识别词表和学校资料。`seed_memories.json`为空数组。

上传这个目录时，`.github/workflows/ios-build.yml`也必须上传，不能上传原始私有工程或其压缩包。公共仓库中的源码及构建产物可被他人查看，私人资料应始终保留在本机；本版本尚未完成私人资料导入功能。

## 免费构建路线

1. 自行在GitHub创建公共仓库；不要为了构建填写付款信息或启用付费runner。
2. 上传本目录文件，确认`.github`目录存在。
3. 在Actions中打开`Build unsigned iPhone app`，点击`Run workflow`。
4. 构建成功后，在该次运行的Artifacts下载`Xiaopihai-unsigned`并解压，获得`Xiaopihai-unsigned.ipa`。
5. 未签名IPA不能直接点击安装，需要在Windows上由支持免费Apple账号的工具重新签名并安装。

工作流支持手动触发及`ios/native-app`分支推送，使用标准`macos-15` runner，不接受Apple密码、签名证书或GitHub Secret。先执行5项模拟器测试，再编译真机目标并打包。首次运行仍可能需要在GitHub启用Actions。

GitHub官方说明公共仓库的标准托管runner免费；私有仓库额度和计费规则不同，使用前检查自己的账户设置。工作流会通过Homebrew安装XcodeGen及使用GitHub官方checkout/artifact动作，未固定完整依赖供应链，尚未实际执行。

## Windows签名安装

可评估Sideloadly的免费个人签名路线，官方地址：https://sideloadly.io/ 。请仅从官方渠道获取安装工具，由用户本人在工具界面输入Apple账号并完成验证，不把密码、验证码、证书发给他人或上传到GitHub。

需要用数据线连接iPhone、信任电脑，并按工具与iOS提示启用开发者模式。Windows侧Apple驱动/iTunes组件要求以工具官方文档为准，不默认卸载或替换电脑现有组件。

官方说明免费签名通常有效7天，支持自动刷新，但刷新有设备与电脑连接条件。到期可能导致App打不开，需重新签名；无法保证永不过期、永久离线续签或后台无感更新。更新必须保持相同应用标识和签名身份，并先验证备份，不能承诺重新安装一定保留数据。

用户报告的iOS版本26.5.2尚未在该工具上实测；网站泛称支持iOS不能替代对具体版本的验证。如官方工具不支持，停止操作，不尝试越狱或利用漏洞绕过签名。

## 验证状态

2026-11-05首次GitHub构建成功，5项模拟器测试全部通过，iPhone目标编译成功并生成未签名IPA。尚未在真实iPhone安装测试。构建成功不代表本地模型、语音和后台通知都能工作；模型尚未接入。

## 官方参考

- GitHub Actions计费：https://docs.github.com/en/billing/concepts/product-billing/github-actions
- Sideloadly免费签名与续签：https://sideloadly.io/
