# PHP 5.3 Apache

This version forked from  https://github.com/cristianorsolin/docker-php-5.3-apache <br />
But cristianorsolin's version have gd problem can not support jpeg and freetype library <br />
I found https://github.com/devilbox/docker-php-fpm-5.3 was solved the problem <br />
<br />
So, I merged them 
<br />
<br />

# Run build
```
docker build -t lanizz/php:5.3-apache .
```

# Docker run
```
docker run -d --name php -p 80:80 -v /root/www:/var/www/html lanizz/php:5.3-apache
```
