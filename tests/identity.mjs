import assert from 'node:assert/strict';
import {familyTitle,firstName} from '../.test-build/identity.js';
assert.equal(familyTitle([{display_name:'Luciano Silva'}]),'Finanças de Luciano');
assert.equal(familyTitle([{display_name:'Luciano Silva'},{display_name:'Nayanne Santos'}]),'Finanças de Luciano e Nayanne');
assert.equal(familyTitle([{display_name:'Luciano'},{display_name:'Nayanne'},{display_name:'João'}]),'Finanças de Luciano, Nayanne e João');
assert.equal(firstName('email@example.com'),'Participante');
console.log('Título dinâmico com um, dois e três participantes e identificação sem e-mail OK');
