/**
 * 生成「AI专题」页面（src/pages/ai.mdx）
 *
 * 扫描 blog/*.md 的 frontmatter，把带 "ai" 标签的文章按日期倒序
 * 生成最新文章列表。发文时打上 ai 标签即可自动收录，无需手工维护。
 *
 * 用法：node scripts/gen-ai-topic.mjs
 * 已挂到 npm predev / prestart / prebuild 钩子上自动执行。
 */
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const BLOG_DIR = 'blog';
const OUT_FILE = 'src/pages/ai.mdx';
const TAG = 'ai';

/** 解析单个文件的 frontmatter（仅支持本站使用的单行字段格式） */
function parsePost(filename) {
    const raw = readFileSync(join(BLOG_DIR, filename), 'utf8');
    const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
    if (!m) return null;
    const fm = m[1];

    const get = (key) => {
        const r = fm.match(new RegExp(`^${key}:\\s*(.+)$`, 'm'));
        return r ? r[1].trim().replace(/^["']|["']$/g, '') : '';
    };

    const title = get('title');
    const date = get('date');
    const draft = get('draft') === 'true';
    let tags = [];
    try {
        tags = JSON.parse(get('tags').replace(/'/g, '"'));
    } catch {
        tags = [];
    }
    if (!title || !date || draft || !tags.includes(TAG)) return null;

    // 文件名格式：YYYY-MM-DD-slug.md → /blog/YYYY/MM/DD/slug
    const m2 = filename.replace(/\.mdx?$/, '').match(/^(\d{4})-(\d{2})-(\d{2})-(.+)$/);
    if (!m2) return null;
    const [, y, mo, d, slug] = m2;
    return { title, date, permalink: `/blog/${y}/${mo}/${d}/${slug}` };
}

const posts = readdirSync(BLOG_DIR)
    .filter((f) => f.endsWith('.md') || f.endsWith('.mdx'))
    .map(parsePost)
    .filter(Boolean)
    .sort((a, b) => (a.date < b.date ? 1 : -1));

const list = posts.map((p) => `- [${p.title}](${p.permalink})`).join('\n');

const page = `---
title: "AI专题"
description: "人工智能相关文章与笔记"
---

{/* 本文件由 scripts/gen-ai-topic.mjs 自动生成，请勿手工编辑。收录规则：blog/ 下带 "ai" 标签的文章，按日期倒序。 */}

# AI专题

人工智能相关文章与笔记。

## AI 知识体系

\`\`\`mermaid
mindmap
  root((AI 知识体系))
    基础理论
      机器学习
        监督学习
        无监督学习
        强化学习
      深度学习
        CNN
        RNN
        GAN
      自然语言处理 NLP
        分词与向量化
        语义理解
        文本生成
    大语言模型 LLM
      核心架构
        Transformer
        Attention 机制
        Positional Encoding
      代表模型
        GPT 系列
        Claude 系列
        DeepSeek
        LLaMA 开源系列
      训练方法
        预训练 Pre-training
        微调 Fine-tuning
        RLHF / DPO
        LoRA / QLoRA
    AI 应用层
      RAG 检索增强生成
        向量数据库
        Embedding 模型
        检索策略
      AI Agent
        工具调用
        记忆系统
        多智能体协作
      Function Calling
        角色与字段
        报文处理
        工具编排
    AI 基础设施
      推理优化
        vLLM
        PagedAttention
        Continuous Batching
        量化推理
      训练框架
        分布式训练
        混合精度
        显存优化
      AI Infra 全景
        GPU 集群
        模型服务
        监控与调度
    AI 协议与标准
      MCP 模型上下文协议
        传输层设计
        工具编排
        资源管理
      A2A 协议
      OpenAI API 规范
    AI 开发工具
      LangChain
      LlamaIndex
      Hermes Agent
      低代码平台
        Dify
        Coze
        n8n
\`\`\`

## 最新文章

${list}
`;

writeFileSync(OUT_FILE, page, 'utf8');
console.log(`已生成 ${OUT_FILE}，收录 ${posts.length} 篇文章`);
