# Fava (Beancount web UI) for 13019691 Canada Inc
# beancount 2.3.x = stable, classic grammar (commodity, links). beancount 3.x
# (the developing major) rewrote the parser and breaks 2.x syntax.
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir beancount==2.3.6 fava
WORKDIR /beancount
EXPOSE 5000
CMD ["fava", "--host", "0.0.0.0", "--port", "5000", "/beancount/main.bean"]