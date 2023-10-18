---
lang: zh-CN
title: 第七空间
description: 个人博客
---

[首页](./index.md)

[配置参考]()

[快速上手]()

[GitHub](https://github.com/feifeigd)

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

<script setup>
    import { useData } from 'vitepress'
    const { page } = useData()
</script>
<pre>{{ page }}</pre>
