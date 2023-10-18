<template>
    当前页面信息：
    <pre>{{ page }}</pre>
</template>

<script setup>
    import { useData } from 'vitepress'
    const { page } = useData()
</script>
