#!/usr/bin/env python3
"""Local-only Windows wizard; no account, network or third-party dependencies."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('mobile_export', ROOT / 'export-mobile.py')
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def cache_candidates(appdata):
    return [Path(appdata) / name / 'schedule-cache.json'
            for name in ['imnu-schedule-float-win', '教务悬浮助手', 'IMNUScheduleFloat']]


def main():
    window = tk.Tk()
    window.title('课表小组件制作 · Windows → iPhone')
    window.geometry('720x340')
    window.minsize(640, 330)
    frame = ttk.Frame(window, padding=22)
    frame.pack(fill='both', expand=True)
    ttk.Label(frame, text='把自己的课表和头像，制作成 iPhone 小组件', font=('', 15, 'bold')).pack(anchor='w')
    ttk.Label(frame, text='先在 Windows 教务助手同步课表。背景可留空；选图请用左侧柔焦、右侧人物的浅色横幅。', wraplength=650).pack(anchor='w', pady=(8, 16))
    cache = tk.StringVar(value=next((str(p) for p in cache_candidates(os.environ.get('APPDATA', '')) if p.is_file()), ''))
    art = tk.StringVar()
    for label, value, filters in [('课表缓存', cache, [('JSON 文件', '*.json')]), ('头像横幅', art, [('PNG / JPEG', '*.png *.jpg *.jpeg')])]:
        row = ttk.Frame(frame); row.pack(fill='x', pady=5)
        ttk.Label(row, text=label, width=9).pack(side='left')
        ttk.Entry(row, textvariable=value).pack(side='left', fill='x', expand=True)
        def choose(v=value, f=filters):
            filename = filedialog.askopenfilename(parent=window, filetypes=f)
            if filename: v.set(filename)
        ttk.Button(row, text='选择…', command=choose).pack(side='left', padx=(8, 0))

    def generate():
        try:
            if not cache.get().strip(): raise ValueError('请先选择 schedule-cache.json。完整步骤见“Windows+iPhone完整流程.html”。')
            raw = json.loads(Path(cache.get()).read_text(encoding='utf-8-sig'))
            data = exporter.sanitize(raw)
            destination = filedialog.askdirectory(parent=window, title='选择保存位置，将自动新建专用包目录')
            if not destination: return
            output = Path(destination) / ('我的课表小组件_' + dt.datetime.now().strftime('%Y%m%d_%H%M%S'))
            exporter.build(output, data, background=Path(art.get()) if art.get().strip() else None)
            messagebox.showinfo('制作完成', '已保存到：\n' + str(output) + '\n\n把其中的“内师大课表.scriptable”通过自己的 iCloud Drive 传到 iPhone。\n专用包包含课程与成绩，请勿发送到公共仓库。', parent=window)
            if os.name == 'nt': os.startfile(output)
        except Exception as error:
            messagebox.showerror('未完成制作', str(error), parent=window)

    ttk.Button(frame, text='选择保存位置并生成', command=generate).pack(anchor='w', pady=(20, 12))
    ttk.Label(frame, text='图片直接内置，无需手机另存。仅本地处理；不上传课表，不读取学校密码。\n首次运行此工具需要 Python 3.10 或更新版本（含 tkinter）。', wraplength=650).pack(anchor='w')
    window.mainloop()


if __name__ == '__main__':
    main()
