---
lang: zh-CN
title: 首页
description: 个人博客
sidebar: auto
# 禁用导航条
# navbar: false

# 页面布局 doc home page
layout: home 

hero:
    name: d7kj 个人博客
    text: 个人静态网站
    # tagline: Lorem ipsum...
    actions:
    - theme: brand
      text: Get Started
      link: /guide/what-is-vitepress
    - theme: alt
      text: View on GitHub
      link: https://github.com/feifeigd

features:
  - icon: ⚡️
    title: Vite, The DX that can't be beat
    details: Lorem ipsum...
  - icon: 🖖
    title: Power of Vue meets Markdown
    details: Lorem ipsum...
  - icon: 🛠️
    title: Simple and minimal, always
    details: Lorem ipsum...
---

[首页](./index.md)

[配置参考]()

[快速上手]()

[GitHub](https://github.com/feifeigd)

[vitepress 文档](https://vitepress.dev/)

# Hello VuePress :tada: ! :100:
[[toc]]

```ts{1,6-8}
import { defaultTheme, defineUserConfig } from 'vuepress'

export default defineUserConfig({
    title: '你好',

    theme: defaultTheme({
        logo: 'https://vuejs.org/images/logo.png',
    })
})
```

一加一等于：{{ 1 + 1 }}
<span v-for="i in 3">span: {{ i }} </span>

![图片](/bg.jpg)

table
|Tables|Are|Cool|
|-|:-:|-:|
|col 3 is | right-aligned|$1600|
|col 2 is |centered|$10|
|zebra stripes|are neat|$1|

::: tip
This is a tip
:::

::: info
This is an info box
:::

::: warning
This is a warning
:::

::: danger
This is a dangerous warning
:::

::: danger STOP
Danger zone, do not proceed
:::

<Page/>
<script setup>
</script>

