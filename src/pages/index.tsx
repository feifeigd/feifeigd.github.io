import type {ReactNode} from 'react';
import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';

import styles from './index.module.css';

const metrics = [
  {value: '10+', label: '年研发经验'},
  {value: '多款', label: '游戏项目上线'},
  {value: 'C++ / Go / Python', label: '服务端主力语言'},
  {value: 'Game + Web', label: '后端全链路能力'},
];

const strengths = [
  {
    title: '游戏服务端架构',
    body: '长期参与 ARPG、卡牌、回合制、H5 与小游戏服务端研发，熟悉战斗、活动、邮件、行会、WebSocket、API 对接与上线维护。',
  },
  {
    title: 'Web 后端与管理后台',
    body: '具备 Web 管理后台、App API、运营工具、收银台、社区平台等后端开发经验，能从业务建模推进到稳定上线。',
  },
  {
    title: '跨语言工程能力',
    body: '熟练使用 C/C++、Go、Python、Java、Lua、TypeScript/JavaScript，也能根据项目阶段快速切换技术栈。',
  },
  {
    title: '上线与运维意识',
    body: '熟悉 Linux 环境、数据库、调试工具、代码管理和线上问题处理，重视可维护性、可观测性和交付节奏。',
  },
];

const projects = [
  {
    name: '小游戏与 API 游戏',
    period: '2026',
    stack: 'Skynet / ThinkPHP / Laravel',
    summary: '完成游戏逻辑、API 游戏对接与后台功能，支撑项目顺利上线。',
  },
  {
    name: '战国少女 / 像素英雄',
    period: '2024 - 2025',
    stack: 'Python / Java',
    summary: '负责卡牌游戏服务端开发、战斗技能开发、上线维护和运维工作。',
  },
  {
    name: 'Go 游戏服务端',
    period: '2023',
    stack: 'Go',
    summary: '从零搭建游戏服务端，推进核心功能开发并完成项目上线。',
  },
  {
    name: 'HTML5 ARPG 项目',
    period: '2016 - 2018',
    stack: 'C++ / Lua / WebSocket',
    summary: '负责服务端功能和底层 WebSocket，完成龙魂、邮件、行会等核心系统。',
  },
];

const timeline = [
  '小游戏与 API 游戏：负责游戏逻辑、平台对接、后台功能和上线交付',
  '卡牌与回合制项目：负责服务端功能、战斗技能、线上维护和运维支持',
  'C++ / Go 服务端项目：参与核心服务开发，并从零搭建管理后台',
  'Web 后端项目：负责业务平台、App API、运营工具和管理后台研发',
  '大型 Webgame / H5 ARPG：沉淀战斗、活动、邮件、行会和 WebSocket 经验',
  '早期游戏研发：覆盖客户端、服务端、工具链和线上功能维护',
];

const skills = [
  'C/C++',
  'Go',
  'Python',
  'Java',
  'Lua',
  'TypeScript',
  'Linux',
  '数据库',
  'Skynet',
  'WebSocket',
  'Laravel',
  'Vue',
  'AI 辅助开发',
];

function Hero(): ReactNode {
  return (
    <section className={styles.hero}>
      <div className={styles.heroContent}>
        <p className={styles.eyebrow}>Game Server & Web Backend Engineer</p>
        <Heading as="h1" className={styles.heroTitle}>
          d7kj
          <span>游戏服务器与 Web 后端工程师</span>
        </Heading>
        <p className={styles.heroText}>
          十年以上软件研发经验，长期深耕游戏服务端、Web 后端和管理后台。
          能从底层服务、业务系统、运营后台到上线维护完整推进交付。
        </p>
        <div className={styles.heroActions}>
          <Link className={styles.primaryButton} to="/docs/">
            查看技术文档
          </Link>
          <Link className={styles.secondaryButton} to="/blog">
            阅读博客
          </Link>
        </div>
      </div>

      <div className={styles.heroVisual} aria-label="服务端能力概览">
        <div className={styles.visualHeader}>
          <span />
          <span />
          <span />
        </div>
        <div className={styles.visualGrid}>
          <div>
            <strong>Game Loop</strong>
            <p>战斗 / 活动 / 任务 / 邮件 / 行会</p>
          </div>
          <div>
            <strong>Backend API</strong>
            <p>管理后台 / App API / 运营工具</p>
          </div>
          <div>
            <strong>Runtime</strong>
            <p>Linux / 数据库 / 调试 / 运维</p>
          </div>
        </div>
        <div className={styles.visualCode}>
          <span>service.status = online</span>
          <span>deploy.target = production</span>
          <span>latency.budget = predictable</span>
        </div>
      </div>
    </section>
  );
}

export default function Home(): ReactNode {
  return (
    <Layout
      title="d7kj - 游戏服务器与 Web 后端工程师"
      description="d7kj 个人宣传网站，展示游戏服务器、Web 后端、管理后台和项目上线经验。">
      <main className={styles.page}>
        <Hero />

        <section className={styles.metrics} aria-label="核心数据">
          {metrics.map((item) => (
            <div className={styles.metric} key={item.label}>
              <strong>{item.value}</strong>
              <span>{item.label}</span>
            </div>
          ))}
        </section>

        <section className={styles.section}>
          <div className={styles.sectionHeading}>
            <p>Capabilities</p>
            <Heading as="h2">我能解决的问题</Heading>
          </div>
          <div className={styles.strengthGrid}>
            {strengths.map((item) => (
              <article className={styles.card} key={item.title}>
                <Heading as="h3">{item.title}</Heading>
                <p>{item.body}</p>
              </article>
            ))}
          </div>
        </section>

        <section className={styles.section}>
          <div className={styles.sectionHeading}>
            <p>Projects</p>
            <Heading as="h2">代表项目经验</Heading>
          </div>
          <div className={styles.projectList}>
            {projects.map((item) => (
              <article className={styles.project} key={item.name}>
                <div>
                  <span>{item.period}</span>
                  <Heading as="h3">{item.name}</Heading>
                </div>
                <p>{item.summary}</p>
                <strong>{item.stack}</strong>
              </article>
            ))}
          </div>
        </section>

        <section className={styles.splitSection}>
          <div>
            <div className={styles.sectionHeading}>
              <p>Experience</p>
              <Heading as="h2">工作轨迹</Heading>
            </div>
            <ol className={styles.timeline}>
              {timeline.map((item) => (
                <li key={item}>{item}</li>
              ))}
            </ol>
          </div>
          <aside className={styles.skillPanel}>
            <Heading as="h2">技术栈</Heading>
            <div className={styles.skillTags}>
              {skills.map((skill) => (
                <span key={skill}>{skill}</span>
              ))}
            </div>
          </aside>
        </section>

        <section className={styles.contact}>
          <div>
            <p className={styles.eyebrow}>Contact</p>
            <Heading as="h2">欢迎交流游戏服务端、Web 后端和项目上线问题</Heading>
          </div>
          <div className={styles.contactActions}>
            <a className={styles.primaryButton} href="mailto:502207456@qq.com">
              发送邮件
            </a>
            <a
              className={styles.secondaryButton}
              href="https://github.com/feifeigd"
              target="_blank"
              rel="noreferrer">
              GitHub
            </a>
          </div>
        </section>
      </main>
    </Layout>
  );
}
