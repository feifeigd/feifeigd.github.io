# 用 LangChain + Qdrant + DeepSeek 搭建简历 RAG 系统

## 背景

需要从一份 Word 简历中提取结构化信息（姓名、专业技能、工作年限），用 RAG 方案比直接写正则解析灵活得多。

## 技术栈

| 组件 | 选型 |
|------|------|
| 文档加载 | UnstructuredLoader |
| 向量库 | Qdrant (Docker) |
| 嵌入模型 | 通义千问 text-embedding-v1 |
| LLM | DeepSeek v4 Flash |
| 编排框架 | LangChain |
| 运行环境 | Python 3.13 + uv |

## 项目结构

```
rag/
├── main.py        # 主流程
├── llm.py         # LLM + 向量库封装
├── prompt.py      # 本地 prompt 模板
├── sensenova.py   # 备用 LLM 客户端
├── pyproject.toml # 依赖管理
└── uv.lock
```

## 核心流程

### 1. 文档加载与切片

```python
word = UnstructuredLoader("简历.docx")
docs = word.load()
splitter = RecursiveCharacterTextSplitter(chunk_size=50, chunk_overlap=20)
chunks = splitter.split_documents(docs)
```

`UnstructuredLoader` 支持 .docx/.pdf/.pptx 等格式，自动提取文本。分片用 50 字符 + 20 字符重叠，对简历这种短文档粒度合适。

### 2. 向量化存储

```python
embeddings = DashScopeEmbeddings(
    dashscope_api_key=os.environ.get("dashscope"),
    model="text-embedding-v1",
)
vectordb = QdrantVectorStore.from_documents(
    chunks, embeddings,
    collection_name="resume",
    url="http://localhost:6333",
)
```

嵌入用通义千问的 `text-embedding-v1`，向量库用 Qdrant（Docker 运行），collection 名 `resume`。

### 3. LCEL 链

```python
chain = {
    "context": vec_store.as_retriever() | format_docs,
    "question": RunnablePassthrough(),
} | prompt | llm | StrOutputParser()
```

用 LangChain Expression Language 串联：检索 → 格式化上下文 → 填充 prompt → LLM 推理 → 解析输出。

### 4. 查询

```python
chain.invoke("请输入姓名. 格式如下\n姓名: ?")
chain.invoke("总结专业技能情况. 格式如下\n专业技能: ?")
chain.invoke("根据工作年份总结工作经验. 格式如下\n工作经验: ?年")
```

三次调用分别提取姓名、技能、工作年限，prompt 里约束了输出格式。

## 实际输出

```
姓名: XX
专业技能: Go, Python, C/C++, C#, Java, Lua
工作经验: 约16年
```

## 踩坑记录

### hub.pull 安全限制

`hub.pull("rlm/rag-prompt")` 默认不允许拉取公开 prompt，需要：

```python
from langsmith import Client as LangSmithClient
client = LangSmithClient()
prompt = client.pull_prompt("rlm/rag-prompt", dangerously_pull_public_prompt=True)
```

### 缺失依赖

`langchain-text-splitters`、`langchain-community`、`dashscope` 需要在 `pyproject.toml` 中显式声明。

### Qdrant 连接

Qdrant 通过 Docker 启动，确保 `localhost:6333` 可访问。

## 完整代码

### main.py

```python
import os

from langchain_openai import OpenAIEmbeddings
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_unstructured import UnstructuredLoader
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnablePassthrough
from langsmith import Client as LangSmithClient

from llm import DeepSeek, QdrantVecStoreFromDocs


def clearstr(s: str) -> str:
    filter_chars = ['\n', '\r', '\t', '\u3000', ' ']
    for char in filter_chars:
        s = s.replace(char, '')
    return s


def format_docs(docs) -> str:
    return "\n\n".join(clearstr(doc.page_content) for doc in docs)


def load_doc():
    word = UnstructuredLoader("C:\\Users\\Administrator\\Downloads\\xxx.docx")
    docs = word.load()
    splitter = RecursiveCharacterTextSplitter(chunk_size=50, chunk_overlap=20)
    chunks = splitter.split_documents(docs)
    vec_store = QdrantVecStoreFromDocs(chunks, collection_name="resume")
    llm = DeepSeek()
    client = LangSmithClient()
    prompt = client.pull_prompt("rlm/rag-prompt", dangerously_pull_public_prompt=True)

    chain = {
        "context": vec_store.as_retriever() | format_docs,
        "question": RunnablePassthrough(),
    } | prompt | llm | StrOutputParser()

    ret = chain.invoke("请输入姓名. 格式如下\n姓名: ?")
    print(ret)
    ret = chain.invoke("总结专业技能情况,内容可能包含golang、AI Agent、python、rag等.格式如下\n专业技能: ?")
    print(ret)
    ret = chain.invoke("根据各大公司工作过的年份总结工作经验有多少年.格式如下\n工作经验: ?年")
    print(ret)


def main():
    print("Hello from rag!")
    load_doc()


if __name__ == "__main__":
    main()
```

### llm.py

```python
import os
from typing import List, Optional

from langchain_community.embeddings import DashScopeEmbeddings
from langchain_core.documents import Document
from langchain_openai import ChatOpenAI
from langchain_qdrant import QdrantVectorStore


def DeepSeek():
    return ChatOpenAI(
        model="deepseek-v4-flash",
        api_key=os.environ.get("DEEPSEEK_API_KEY"),
        base_url="https://api.deepseek.com/v1",
    )


def get_embeddings():
    return DashScopeEmbeddings(
        dashscope_api_key=os.environ.get("dashscope"),
        model="text-embedding-v1",
    )


def QdrantVecStoreFromDocs(docs: List[Document], collection_name: str,
                           qdrant_url: Optional[str] = None,
                           qdrant_api_key: Optional[str] = None):
    if qdrant_url is None:
        qdrant_url = "http://localhost:6333"
    embeddings = get_embeddings()
    vectordb = QdrantVectorStore.from_documents(
        docs, embeddings, collection_name=collection_name,
        url=qdrant_url, api_key=qdrant_api_key,
    )
    return vectordb
```

### prompt.py

```python
RAGPrompt = """
You are an assistant for question-answering tasks.
Use the following pieces of retrieved context to answer the question.
If you don't know the answer, just say that you don't know,
don't try to make up an answer.
Use three sentences maximum and keep the answer concise.
Question: {question}
Context: {context}
Answer:
"""
```

### pyproject.toml

```toml
[project]
name = "rag"
version = "0.1.0"
description = "Add your description here"
readme = "README.md"
requires-python = ">=3.13"
dependencies = [
    "langchain>=1.3.11",
    "langchain-unstructured>=0.1.0",
    "langchain-openai>=1.3.3",
    "langchain-text-splitters>=0.3.0",
    "langchain-community>=0.3.0",
    "nltk>=3.9.4",
    "python-docx>=1.2.0",
    "unstructured>=0.23.1",
    "langchain-qdrant>=1.1.0",
    "dashscope>=1.0.0",
]
```

## 总结

LangChain 的 LCEL 写 RAG pipeline 非常简洁，配合 Docker 运行的 Qdrant 和 DeepSeek 的 API，从文档到结构化输出只要几十行代码。这套方案不仅适用于简历解析，合同审核、知识库 QA 等场景也能直接复用。
