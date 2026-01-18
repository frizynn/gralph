- los rpeorts y progress se pasan entre agentes
- poder correr con permisos: allow all para que incluso cuando detecte fallos del SO o de entorno que un agente se trigeree para corregirlos

- ver si el mutex en realdiad es necesario (hasta ahora no se usó en los agentes)
- ver que cosas son necesarias realmente
- ahora parece secuencial en la mayoria de casos, ver como se puede paralelizar mejor. En el contrato entre tasks definir que cosa va a hacer cada una y como, asi la otra puede desarrollar su parte sin interferir en la otra.