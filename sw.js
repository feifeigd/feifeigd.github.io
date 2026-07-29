console.log('this sw.js');

importScripts('https://storage.googleapis.com/workbox-cdn/releases/4.1.1/workbox-sw.js');

if (workbox) {
  console.log(`Yay! Workbox is loaded 🎉`);
} else {
  console.log(`Boo! Workbox didn't load 😬`);
}

const cacheName = 'HelloWorld';

// Service Worker 安装事件
self.addEventListener('install', event=>{
    event.waitUntil(caches.open(cacheName)
        .then(cache=>{
            // 添加到缓存中
            cache.addAll([
                'favicon.ico'
            ]);
        }));
});

self.addEventListener('fetch', event=>{
    event.respondWith(caches.match(event.request)
        .then(response=>{
            if(response)return response;
            // 复制请求。请求是一个流，只能使用一次            
            let requestToCache = event.request.clone();

            return fetch(requestToCache).then(response=>{
                if(!response || response.status !== 200)
                    return response;
                // 复制响应，因为需要将其添加到缓存中，而且它还将用于最终返回响应
                let responseToCache = response.clone();
                // 添加至缓存中
                caches.open(cacheName).then(cache=>{
                    cache.put(requestToCache, responseToCache);
                });
                return response;
            });
        }));    

});
