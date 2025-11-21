---
lang: zh-CN
title: 首页
description: 个人博客
sidebar: auto
# 禁用导航条
# navbar: false

# 页面布局 doc home page
# https://vitepress.dev/reference/default-theme-home-page
layout: home 

hero:
    name: d7kj 个人博客
    text: 个人静态网站
    tagline: 记录工作和学习过程中的笔记：C/C++，服务器开发，Linux笔记
    actions:
    - theme: brand
      text: Get Started
      link: /guide/what-is-vitepress
    - theme: alt
      text: View on GitHub
      link: https://github.com/feifeigd
    - theme: alt
      text: API Example
      link: /api-examples

features:
  - icon: ⚡️
    title: 个人简介
    details: 主要涉及技术：C/C++服务器开发，Linux
  - icon: 🖖
    title: 开发笔记
    details: C/C++比较，Linux笔记
  - icon: 🛠️
    title: github项目
    details: 架构设计，设计模式，框架使用
---

<VPTeamMembers size="small" :members="members" />

[首页](./index.md)

[GitHub](https://github.com/feifeigd)

[vitepress 文档](https://vitepress.dev/)

# Hello VuePress :tada: ! :100:


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

<!-- <Page/> -->

<script setup>
import VPTeamMembers from "vitepress/theme";
const members = [
    {
        avatar: 'https://www.github.com/yyx990803.png',
        name: 'Evan You',
        title: 'Creator',
        links: [
        { icon: 'github', link: 'https://github.com/yyx990803' },
        { icon: 'twitter', link: 'https://twitter.com/youyuxi' }
        ]
    },
];
// config.ts 定义的变量
const date = __DATE__
</script>

<pre>Generated: {{ date }} </pre>
