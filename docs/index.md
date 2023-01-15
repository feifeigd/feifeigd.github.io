---
lang: zh-CN
title: 第七空间
description: 个人博客
---

[首页](./index.md)
[配置参考]()
[快速上手]()
[GitHub](https://github.com/feifeigd)

# Hello VuePress :tada: !
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
