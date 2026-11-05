"""免费本机窗口控制端：局域网配对、记忆整理和人物资料；仅使用Python标准库。"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import copy
import hmac
import html
import ipaddress
import json
import os
import secrets
import socket
import threading
import time
try:
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox
except ImportError:
    tk = None  # 云端无图形库时仍能运行网络与数据回归测试。
import uuid
from urllib.parse import urlsplit, parse_qs, urlencode

ROOT = Path(__file__).resolve().parent / 'data'
LOCK = threading.RLock()
LIMIT = 12_000_000


def atomic_json(path, data):
    """同目录临时文件原子替换，保存失败不截断旧配置。"""
    temporary = path.with_suffix('.pending')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, path)


def now():
    # Swift默认日期以2001年为原点。
    return time.time() - 978307200


def default_config():
    return dict(schemaVersion=1, revision=str(uuid.uuid4()).upper(), memories=[], deletedMemoryIDs=[],
                owner=dict(name='用户', account='', region='', signature=''),
                character=dict(name='小屁孩', account='', region='', signature=''),
                settings=dict(relationship='分手后', proactivity=0.55, emotionalVariation=0.55,
                              intimacy=0.35, notifications=False))


def validate(config):
    if config.get('schemaVersion') != 1:
        raise ValueError('不支持的配置版本')
    uuid.UUID(config['revision'])
    ids = set()
    for item in config['memories']:
        uuid.UUID(item['id'])
        if item['id'] in ids or not item['content'].strip() or len(item['content']) > 2000:
            raise ValueError('记忆ID重复或内容无效')
        ids.add(item['id'])
        if item['category'] not in ['事实', '关系', '习惯', '计划', '事件', '设定'] or not 1 <= item['importance'] <= 5:
            raise ValueError('记忆分类或重要程度无效')
    if len(ids) > 10000 or ids.intersection(config['deletedMemoryIDs']):
        raise ValueError('记忆数量超限或删除标记冲突')
    for identifier in config['deletedMemoryIDs']:
        uuid.UUID(identifier)
    for key in ['owner', 'character']:
        profile = config[key]
        for name, bound in [('name', 60), ('account', 80), ('region', 120), ('signature', 300)]:
            if len(profile.get(name, '')) > bound:
                raise ValueError('人物资料长度超限')
        if not profile['name'].strip():
            raise ValueError('名字不能为空')
        if profile.get('avatar') and len(base64.b64decode(profile['avatar'], validate=True)) > 2_000_000:
            raise ValueError('头像超过2MB')
    for name in ['proactivity', 'intimacy', 'emotionalVariation']:
        if not 0 <= config['settings'][name] <= 1:
            raise ValueError('人物参数必须在0至1之间')
    return config


class Repository:
    def __init__(self, root=ROOT):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        path = root / 'config.json'
        initialized = root / 'initialized.txt'
        self.pristine = not initialized.exists()
        self.config = validate(json.loads(path.read_text(encoding='utf-8'))) if path.exists() else default_config()
        token_path = root / 'pair-token.txt'
        self.token = token_path.read_text().strip() if token_path.exists() else secrets.token_hex(32)
        if len(self.token) != 64:
            raise ValueError('配对文件损坏，停止启动以保护旧数据')
        token_path.write_text(self.token, encoding='ascii')
        self.last_sync = None
        self.persist()

    def persist(self):
        validate(self.config)
        atomic_json(self.root / 'config.json', self.config)

    def update(self, value):
        value = copy.deepcopy(value)
        value['revision'] = str(uuid.uuid4()).upper()
        validate(value)
        with LOCK:
            atomic_json(self.root / 'config.json', value)
            self.config = value
            self.pristine = False
            (self.root / 'initialized.txt').write_text('configured', encoding='ascii')

    def state(self, value):
        if value.get('schemaVersion') != 3 or not isinstance(value.get('messages'), list):
            raise ValueError('无效手机状态')
        with LOCK:
            if self.pristine:
                config = default_config()
                for key in ['memories', 'owner', 'character', 'settings']:
                    if key in value: config[key] = copy.deepcopy(value[key])
                validate(config)
                atomic_json(self.root / 'config.json', config)
                self.config = config
                self.pristine = False
                (self.root / 'initialized.txt').write_text('paired', encoding='ascii')
            atomic_json(self.root / 'phone-state.json', value)
            self.last_sync = time.time()


def handler(repository):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # 不把配对令牌或私人请求写入控制台日志。

        def reply(self, status, value):
            data = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authenticated(self):
            expected = 'Bearer ' + repository.token
            if not hmac.compare_digest(self.headers.get('Authorization', ''), expected):
                self.reply(401, {'error': '未配对'})
                return False
            return True

        def do_GET(self):
            parts = urlsplit(self.path)
            if parts.path == '/pair':
                query = parse_qs(parts.query)
                if not hmac.compare_digest(query.get('token', [''])[0], repository.token):
                    self.reply(401, {'error': '未配对'}); return
                host = self.server.server_address[0]
                link = 'xiaopihai://pair?' + urlencode(dict(host=host, port=self.server.server_address[1], token=repository.token))
                body = ('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
                        '<title>连接电脑控制端</title><main style="font:20px sans-serif;padding:32px">'
                        '<h2>连接自己的电脑</h2><p>请确认手机与电脑处于同一可信Wi-Fi。</p>'
                        '<a href="' + html.escape(link, quote=True) + '">打开小屁孩并配对</a>'
                        '<p>首次使用请允许App访问本地网络。</p></main>').encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Referrer-Policy', 'no-referrer')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body); return
            if not self.authenticated():
                return
            if self.path == '/health':
                self.reply(200, {'ok': True})
            elif self.path == '/config':
                with LOCK:
                    self.reply(200, repository.config)
            else:
                self.reply(404, {'error': '未找到'})

        def do_POST(self):
            if not self.authenticated():
                return
            if self.path != '/state':
                self.reply(404, {'error': '未找到'})
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= LIMIT:
                    self.reply(413, {'error': '数据大小超限'})
                    return
                self.connection.settimeout(10)
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError('数据不完整')
                repository.state(json.loads(body))
                self.reply(200, {'ok': True})
            except (ValueError, KeyError, OSError):
                self.reply(400, {'error': '手机状态无效，旧文件已保留'})
    return Handler


def local_addresses():
    addresses = []
    for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
        value = item[4][0]
        address = ipaddress.ip_address(value)
        if address.is_private and not address.is_loopback and not address.is_link_local and value not in addresses:
            addresses.append(value)
    return addresses


class Window:
    def __init__(self, root, repository):
        self.root, self.repository = root, repository
        self.config = copy.deepcopy(repository.config)
        self.server = None
        self.selected_id = None
        root.title('小屁孩 · 电脑控制端')
        root.geometry('960x720')
        tabs = ttk.Notebook(root)
        tabs.pack(fill='both', expand=True, padx=12, pady=12)
        memories, profiles, sync = (ttk.Frame(tabs) for _ in range(3))
        for frame, title in [(memories, '记忆管理'), (profiles, '人物与情绪'), (sync, '手机连接')]:
            tabs.add(frame, text=title)
        self.tree = ttk.Treeview(memories, columns=('category', 'importance', 'content'), show='headings', height=14)
        for name, text, width in [('category', '分类', 80), ('importance', '重要程度', 80), ('content', '内容', 650)]:
            self.tree.heading(name, text=text); self.tree.column(name, width=width)
        self.tree.pack(fill='both', expand=True, padx=8, pady=8)
        self.tree.bind('<<TreeviewSelect>>', self.select_memory)
        row = ttk.Frame(memories); row.pack(fill='x', padx=8)
        self.category = tk.StringVar(value='事实')
        ttk.Combobox(row, textvariable=self.category, values=['事实', '关系', '习惯', '计划', '事件', '设定'], state='readonly', width=10).pack(side='left')
        self.importance = tk.IntVar(value=3)
        ttk.Spinbox(row, from_=1, to=5, textvariable=self.importance, width=5).pack(side='left', padx=8)
        self.content = tk.Text(memories, height=5); self.content.pack(fill='x', padx=8, pady=8)
        buttons = ttk.Frame(memories); buttons.pack(fill='x', padx=8, pady=8)
        for title, action in [('新增/保存修改', self.save_memory), ('清空输入', self.clear_memory), ('删除选中记忆', self.delete_memory), ('接收手机记忆', self.merge_phone)]:
            ttk.Button(buttons, text=title, command=action).pack(side='left', padx=4)
        self.fields = {}
        for key, title in [('owner', '我的资料'), ('character', '对方资料')]:
            frame = ttk.LabelFrame(profiles, text=title); frame.pack(fill='x', padx=8, pady=8)
            self.fields[key] = {}
            for name, label in [('name', '名字'), ('account', '微信号'), ('region', '地区'), ('signature', '个性签名')]:
                line = ttk.Frame(frame); line.pack(fill='x', padx=8, pady=3)
                ttk.Label(line, text=label, width=12).pack(side='left')
                variable = tk.StringVar(value=self.config[key].get(name, ''))
                self.fields[key][name] = variable
                ttk.Entry(line, textvariable=variable).pack(side='left', fill='x', expand=True)
            ttk.Button(frame, text='选择头像（JPG/PNG，2MB以内）', command=lambda key=key: self.avatar(key)).pack(pady=5)
        self.parameters = {}
        for key, label in [('proactivity', '主动程度'), ('intimacy', '亲密程度'), ('emotionalVariation', '情绪波动')]:
            row = ttk.Frame(profiles); row.pack(fill='x', padx=16, pady=3)
            ttk.Label(row, text=label, width=12).pack(side='left')
            variable = tk.DoubleVar(value=self.config['settings'][key]); self.parameters[key] = variable
            ttk.Scale(row, from_=0, to=1, variable=variable).pack(fill='x', expand=True)
        self.notifications = tk.BooleanVar(value=self.config['settings']['notifications'])
        ttk.Checkbutton(profiles, text='允许预生成主动消息通知（尚未接入生成模型）', variable=self.notifications).pack(pady=5)
        ttk.Button(profiles, text='保存人物配置', command=self.save_profiles).pack(pady=8)
        ttk.Button(profiles, text='读取手机当前资料', command=self.load_phone_profiles).pack(pady=4)
        ttk.Label(sync, text='手机和电脑接入同一可信Wi-Fi；只在此窗口运行期间提供同步。', wraplength=850).pack(pady=12)
        self.host = tk.StringVar(value=next(iter(local_addresses()), '192.168.1.2'))
        ttk.Label(sync, text='本机局域网IPv4（多网卡时确认Wi-Fi地址）').pack()
        ttk.Entry(sync, textvariable=self.host, width=35).pack(pady=6)
        ttk.Button(sync, text='开启局域网控制端', command=self.start).pack(pady=8)
        self.pair = tk.Text(sync, height=4, wrap='word'); self.pair.pack(fill='x', padx=16, pady=8)
        ttk.Button(sync, text='复制配对链接', command=self.copy_link).pack(pady=4)
        ttk.Label(sync, text='将链接发送到自己手机，用Safari打开并允许跳转到App。\n配对后打开App会自动同步；电脑可关闭，聊天记录仍在手机。\n使用带随机令牌的局域网HTTP，传输没有TLS加密，只用于可信私人Wi-Fi。\n不要把配对链接发给别人，不要将此端口暴露到互联网。', wraplength=850).pack(pady=12)
        self.status = tk.StringVar(value='尚未连接手机；配置与接收的手机状态仅存放在D盘本机data目录。')
        ttk.Label(root, textvariable=self.status, wraplength=920).pack(fill='x', padx=12, pady=8)
        self.refresh()
        root.protocol('WM_DELETE_WINDOW', self.close)
        self.tick()

    def refresh(self):
        self.tree.delete(*self.tree.get_children())
        for item in sorted(self.config['memories'], key=lambda x: (x['category'], -x['importance'])):
            self.tree.insert('', 'end', iid=item['id'], values=(item['category'], item['importance'], item['content']))

    def select_memory(self, _event):
        selection = self.tree.selection()
        if not selection: return
        item = next(x for x in self.config['memories'] if x['id'] == selection[0])
        self.selected_id = item['id']; self.category.set(item['category']); self.importance.set(item['importance'])
        self.content.delete('1.0', 'end'); self.content.insert('1.0', item['content'])

    def clear_memory(self):
        self.selected_id = None; self.content.delete('1.0', 'end')

    def persist(self):
        self.repository.update(self.config)
        self.config = copy.deepcopy(self.repository.config)
        self.status.set('配置已保存；手机回到App前台时自动同步。人物参数在生成模型接入后生效。')
        self.refresh()

    def save_memory(self):
        try:
            text = self.content.get('1.0', 'end').strip()
            if not text: raise ValueError('请输入记忆内容')
            existing = next((x for x in self.config['memories'] if x['id'] == self.selected_id), None)
            if existing is None:
                existing = dict(id=str(uuid.uuid4()).upper(), createdAt=now(), source='电脑控制端补充')
                self.config['memories'].append(existing)
            existing.update(category=self.category.get(), importance=self.importance.get(), content=text, updatedAt=now())
            self.persist(); self.clear_memory()
        except Exception as error: messagebox.showerror('无法保存', str(error))

    def delete_memory(self):
        if not self.selected_id: return
        if not messagebox.askyesno('删除记忆', '此操作会在下一次同步时删除手机对应记忆，是否继续？'): return
        self.config['deletedMemoryIDs'].append(self.selected_id)
        self.config['memories'] = [x for x in self.config['memories'] if x['id'] != self.selected_id]
        self.persist(); self.clear_memory()

    def avatar(self, key):
        filename = filedialog.askopenfilename(filetypes=[('图片', '*.jpg *.jpeg *.png')])
        if not filename: return
        data = Path(filename).read_bytes()
        if len(data) > 2_000_000:
            messagebox.showerror('头像过大', '请选择2MB以内图片，尺寸不超过4096×4096。'); return
        self.config[key]['avatar'] = base64.b64encode(data).decode('ascii')
        self.status.set('头像已选择，点击“保存人物配置”提交。')

    def save_profiles(self):
        try:
            for key, fields in self.fields.items():
                for name, variable in fields.items(): self.config[key][name] = variable.get().strip()
            for key, variable in self.parameters.items(): self.config['settings'][key] = variable.get()
            self.config['settings']['notifications'] = self.notifications.get()
            self.persist()
        except Exception as error: messagebox.showerror('无法保存', str(error))

    def merge_phone(self):
        path = self.repository.root / 'phone-state.json'
        if not path.exists(): messagebox.showinfo('未收到手机状态', '先完成手机配对并打开一次App。'); return
        phone = json.loads(path.read_text(encoding='utf-8'))
        by_id = {x['id']: x for x in self.config['memories']}
        for item in phone['memories']:
            if item['id'] in self.config['deletedMemoryIDs']: continue
            if item['id'] not in by_id or item['updatedAt'] > by_id[item['id']]['updatedAt']: by_id[item['id']] = item
        self.config['memories'] = list(by_id.values())
        self.persist()

    def load_phone_profiles(self):
        path = self.repository.root / 'phone-state.json'
        if not path.exists(): messagebox.showinfo('未收到手机状态', '先完成手机配对并打开一次App。'); return
        phone = json.loads(path.read_text(encoding='utf-8'))
        for key in ['owner', 'character']:
            self.config[key] = copy.deepcopy(phone[key])
            for name, variable in self.fields[key].items(): variable.set(phone[key].get(name, ''))
        self.status.set('已读取手机当前资料，确认后点击保存人物配置。')

    def start(self):
        try:
            address = ipaddress.ip_address(self.host.get().strip())
            if address.version != 4 or not address.is_private or address.is_loopback or address.is_link_local:
                raise ValueError('请输入电脑Wi-Fi的私人局域网IPv4地址')
            if self.server is None:
                self.server = ThreadingHTTPServer((str(address), 8765), handler(self.repository))
                self.server.daemon_threads = True
                threading.Thread(target=self.server.serve_forever, daemon=True).start()
            host = self.server.server_address[0]
            link = f'http://{host}:8765/pair?token={self.repository.token}'
            self.pair.delete('1.0', 'end'); self.pair.insert('1.0', link)
            self.status.set('局域网服务已开启，若Windows提示防火墙权限，只允许私人网络。')
        except Exception as error: messagebox.showerror('无法启动局域网同步', str(error))

    def copy_link(self):
        value = self.pair.get('1.0', 'end').strip()
        if value: self.root.clipboard_clear(); self.root.clipboard_append(value)

    def tick(self):
        if self.repository.last_sync:
            self.status.set('手机最近同步时间：' + time.strftime('%H:%M:%S', time.localtime(self.repository.last_sync)))
        self.root.after(2000, self.tick)

    def close(self):
        if self.server: self.server.shutdown(); self.server.server_close()
        self.root.destroy()


if __name__ == '__main__':
    if tk is None: raise SystemExit('此电脑Python缺少Tk图形组件，请安装带Tk的Python。')
    app = tk.Tk()
    try:
        Window(app, Repository())
    except Exception as error:
        messagebox.showerror('控制端启动失败，原文件未覆盖', str(error)); app.destroy()
    else:
        app.mainloop()
