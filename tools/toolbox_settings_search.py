"""Public settings metadata only: no configuration, credentials, history or network reads."""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from configuration_schema import MODULES
from toolbox_controls import FEATURES

PAGES = {'general':'常规','hotkeys':'功能与快捷键','translate':'翻译设置','tts':'朗读设置','ocr':'截图识别',
         'capture':'截图与录屏','audio':'音频切换','theme':'主题、壁纸与背光','power':'电源与唤醒','rgb':'氛围灯'}
BASICS = {
    'translate': [('engine','首选翻译引擎'),('source_language','原文语言'),('target_language','目标语言'),
                  ('fallback_without_credentials','未配置密钥时使用 Google 保底'),('fallback_on_auth_error','鉴权失败时静默使用 Google 保底'),('long_text_enabled','长文分段翻译')],
    'tts': [('engine','朗读方式'),('zh_voice','中文音色'),('en_voice','英文音色'),('rate','语速（%）'),('pitch','音调（Hz）'),('volume','音量调整（%）')],
}


def catalog() -> dict:
    items = []
    def add(page, kind, target, label, aliases=''):
        items.append({'page':page,'page_label':PAGES[page],'kind':kind,'target':target,'label':label,
                      'keywords':aliases,'id':page+':'+kind+':'+target})
    for page, label in PAGES.items():
        add(page,'page','',label)
        if page in MODULES: add(page,'module','module_'+page+'_enabled','启用'+label,'开启 关闭 功能开关')
    for page, spec in MODULES.items():
        for field in spec['fields']:
            add(page,'field',field['key'],field['label'],field['key']+' '+field['help'])
    for page, fields in BASICS.items():
        for key, label in fields: add(page,'preference',key,label,key+' '+('TTS 语音 声音' if page=='tts' else 'translation'))
    add('general','control','tray_visible','显示工具箱主托盘图标','托盘 隐藏 tray')
    for feature, label, _, kind in FEATURES:
        add('hotkeys','control','feature_'+feature+'_enabled',label,'功能开关 '+feature)
        if kind not in ('leader','resident'):
            aliases = {'SpeakSelectedText':'朗读快捷键 TTS','TranslateSelectedText':'翻译快捷键','ScreenshotTranslate':'截图翻译快捷键','AudioSwitcher':'音频快捷键'}.get(feature,'')
            add('hotkeys','control','binding_'+feature,label+'快捷键','热键 hotkey '+feature+' '+aliases)
    for provider, label in (('tencent','腾讯云'),('aliyun','阿里云')):
        add('translate','credential',provider,label+'密钥','key secret API 凭证 '+provider)
    add('general','section','diagnostics','运行状态与版本','诊断 进程 status')
    add('general','section','maintenance','维护操作','重载 离线检查 依赖 环境')
    add('capture','section','capture_activity','最近捕获处理','截图 录屏 结果 剪贴板 额外目录')
    return {'status':'ok','version':1,'items':items}


def main() -> int:
    if hasattr(sys.stdout,'reconfigure'): sys.stdout.reconfigure(encoding='utf-8')
    print(json.dumps(catalog(),ensure_ascii=False)); return 0


if __name__ == '__main__': raise SystemExit(main())
